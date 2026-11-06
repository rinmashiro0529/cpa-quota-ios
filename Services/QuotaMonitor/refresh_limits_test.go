package monitor

import (
	"bytes"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"testing"
	"time"
)

func refreshTestService(t *testing.T) (*Service, *clock, *batchPersistence) {
	t.Helper()
	base, clock, _ := testService(t)
	options := base.options()
	store := &batchPersistence{}
	options.Store, options.CPA = store, nil
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Close)
	return service, clock, store
}

func requireRefreshStatus(t *testing.T, response *http.Response, status, retry int) {
	t.Helper()
	defer response.Body.Close()
	if response.StatusCode != status {
		t.Fatalf("refresh status %s, want %d", response.Status, status)
	}
	if retry > 0 {
		if response.Header.Get("Retry-After") != strconv.Itoa(retry) || response.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("rate limit has no accurate retry policy: %v", response.Header)
		}
	} else if response.Header.Get("Retry-After") != "" {
		t.Fatal("an accepted refresh made an unnecessary retry promise")
	}
}

func TestDuplicatePendingRefreshDoesNotWriteAgain(t *testing.T) {
	service, clock, store := refreshTestService(t)
	requireCapacityStatus(t, service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()), http.StatusCreated)
	store.reset()
	path := "/v1/monitoring/sessions/" + sessionID + "/refresh"
	requireRefreshStatus(t, service.call(t, http.MethodPost, path, "bridge", nil), http.StatusAccepted, 0)
	firstWrites, first := store.result()
	if firstWrites != 1 {
		t.Fatalf("initial refresh persisted %d times, want 1", firstWrites)
	}
	requireRefreshStatus(t, service.call(t, http.MethodPost, path, "bridge", nil), http.StatusTooManyRequests, 10)
	clock.Advance(9500 * time.Millisecond)
	requireRefreshStatus(t, service.call(t, http.MethodPost, path, "bridge", nil), http.StatusTooManyRequests, 1)
	clock.Advance(500 * time.Millisecond)
	requireRefreshStatus(t, service.call(t, http.MethodPost, path, "bridge", nil), http.StatusAccepted, 0)
	clock.Advance(manualRefreshSpacing)
	requireRefreshStatus(t, service.call(t, http.MethodPost, path, "bridge", nil), http.StatusAccepted, 0)
	writes, after := store.result()
	if writes != 1 || !bytes.Equal(first, after) {
		t.Fatal("an unchanged pending intent caused another durable write")
	}
}

func TestPrincipalRefreshBudgetDoesNotBlockOtherPrincipalOrControl(t *testing.T) {
	service, clock, store := refreshTestService(t)
	path := "/v1/monitoring/sessions"
	var ids []string
	for i := 0; i < principalRefreshBurst+1; i++ {
		request := registration()
		id := fmt.Sprintf("%08x-1111-4111-8111-111111111111", i+1)
		request["id"] = id
		ids = append(ids, id)
		requireCapacityStatus(t, service.call(t, http.MethodPost, path, "bridge", request), http.StatusCreated)
	}
	other := registration()
	other["id"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "other-bridge", other), http.StatusCreated)
	store.reset()
	for _, id := range ids[:principalRefreshBurst] {
		requireRefreshStatus(t, service.call(t, http.MethodPost, path+"/"+id+"/refresh", "bridge", nil), http.StatusAccepted, 0)
	}
	rejectedPath := path + "/" + ids[principalRefreshBurst]
	beforeWrites, before := store.result()
	requireRefreshStatus(t, service.call(t, http.MethodPost, rejectedPath+"/refresh", "bridge", nil), http.StatusTooManyRequests, 60)
	writes, after := store.result()
	if beforeWrites != principalRefreshBurst || writes != beforeWrites || !bytes.Equal(before, after) {
		t.Fatal("principal rate rejection mutated durable state")
	}
	requireRefreshStatus(t, service.call(t, http.MethodPost, path+"/"+other["id"].(string)+"/refresh", "other-bridge", nil), http.StatusAccepted, 0)
	requireCapacityStatus(t, service.call(t, http.MethodGet, rejectedPath, "bridge", nil), http.StatusOK)
	requireCapacityStatus(t, service.call(t, http.MethodPut, path+"/"+ids[0]+"/token", "bridge", map[string]any{"push_token": "cdef", "revision": 1}), http.StatusOK)
	requireCapacityStatus(t, service.call(t, http.MethodDelete, rejectedPath, "bridge", nil), http.StatusOK)
	// At exactly one rolling minute the principal budget is available again.
	clock.Advance(principalRefreshWindow)
	requireRefreshStatus(t, service.call(t, http.MethodPost, path+"/"+ids[0]+"/refresh", "bridge", nil), http.StatusAccepted, 0)
}

func TestConcurrentRefreshHasOneDurableAcceptance(t *testing.T) {
	service, _, store := refreshTestService(t)
	requireCapacityStatus(t, service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()), http.StatusCreated)
	store.reset()
	path := "/v1/monitoring/sessions/" + sessionID + "/refresh"
	statuses := make(chan int, 4)
	start := make(chan struct{})
	var requests sync.WaitGroup
	for i := 0; i < cap(statuses); i++ {
		requests.Add(1)
		go func() {
			defer requests.Done()
			<-start
			response := service.call(t, http.MethodPost, path, "bridge", nil)
			defer response.Body.Close()
			statuses <- response.StatusCode
		}()
	}
	close(start)
	requests.Wait()
	close(statuses)
	accepted, limited := 0, 0
	for status := range statuses {
		switch status {
		case http.StatusAccepted:
			accepted++
		case http.StatusTooManyRequests:
			limited++
		default:
			t.Fatalf("unexpected response %d", status)
		}
	}
	writes, _ := store.result()
	if accepted != 1 || limited != 3 || writes != 1 {
		t.Fatalf("refresh admission was not atomic: accepted %d, limited %d, writes %d", accepted, limited, writes)
	}
}

func TestRefreshBudgetIgnoresUnknownForeignAndTerminalSessions(t *testing.T) {
	service, _, _ := refreshTestService(t)
	path := "/v1/monitoring/sessions"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "other-bridge", registration()), http.StatusCreated)
	for _, id := range []string{sessionID, "22222222-2222-4222-8222-222222222222"} {
		requireCapacityStatus(t, service.call(t, http.MethodPost, path+"/"+id+"/refresh", "bridge", nil), http.StatusNotFound)
	}
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"/"+sessionID, "other-bridge", nil), http.StatusOK)
	requireRefreshStatus(t, service.call(t, http.MethodPost, path+"/"+sessionID+"/refresh", "other-bridge", nil), http.StatusAccepted, 0)
	service.mu.Lock()
	defer service.mu.Unlock()
	if len(service.refreshes.sessions) != 0 || len(service.refreshes.principals) != 0 {
		t.Fatal("unaccepted activity identifiers allocated refresh limiter state")
	}
}

func TestRefreshBudgetDoesNotReopenOnClockRollback(t *testing.T) {
	service, clock, store := refreshTestService(t)
	requireCapacityStatus(t, service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()), http.StatusCreated)
	store.reset()
	path := "/v1/monitoring/sessions/" + sessionID + "/refresh"
	requireRefreshStatus(t, service.call(t, http.MethodPost, path, "bridge", nil), http.StatusAccepted, 0)
	clock.Advance(-time.Minute)
	requireRefreshStatus(t, service.call(t, http.MethodPost, path, "bridge", nil), http.StatusTooManyRequests, 70)
	if writes, _ := store.result(); writes != 1 {
		t.Fatal("clock rollback caused another refresh write")
	}
}
