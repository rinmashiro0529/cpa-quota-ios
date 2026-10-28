package monitor

import (
	"context"
	"time"
)

type sourceRound struct {
	done    chan struct{}
	cancel  context.CancelFunc
	started int64
}

func (s *Service) collect(parent context.Context, ids []string) {
	if s.opt.CPA == nil || len(ids) == 0 {
		return
	}
	s.mu.Lock()
	if !s.availableLocked() {
		s.mu.Unlock()
		return
	}
	sources := map[string]bool{}
	now := s.opt.Now().Unix()
	for _, id := range ids {
		record, ok := s.state.Sessions[id]
		if ok && record.Status == "active" && now < record.ExpiresAt {
			sources[record.SourceID] = true
		}
	}
	var waiting []<-chan struct{}
	for source := range sources {
		if current := s.rounds[source]; current != nil {
			waiting = append(waiting, current.done)
			continue
		}
		if last := s.lastRound[source]; last != 0 && now < last+int64(refreshSpacing/time.Second) {
			continue
		}
		var accounts, targets []string
		seen := map[string]bool{}
		for id, record := range s.state.Sessions {
			if record.SourceID != source || record.Status != "active" || now >= record.ExpiresAt {
				continue
			}
			targets = append(targets, id)
			for _, account := range record.AccountIDs {
				if !seen[account] {
					seen[account] = true
					accounts = append(accounts, account)
				}
			}
		}
		if len(targets) == 0 {
			continue
		}
		ctx, cancel := context.WithTimeout(s.ctx, roundTimeout)
		round := &sourceRound{done: make(chan struct{}), cancel: cancel, started: now}
		s.rounds[source], s.lastRound[source] = round, now
		waiting = append(waiting, round.done)
		s.workers.Add(1)
		go s.runRound(ctx, source, round, targets, accounts)
	}
	s.mu.Unlock()
	for _, done := range waiting {
		select {
		case <-done:
		case <-parent.Done():
			return
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *Service) runRound(ctx context.Context, source string, round *sourceRound, targets, accounts []string) {
	defer s.workers.Done()
	defer round.cancel()
	readings := s.opt.CPA.Collect(ctx, source, accounts)
	if s.ctx.Err() == nil {
		if ctx.Err() != nil {
			readings = nil
		}
		s.apply(source, targets, readings)
	}
	s.mu.Lock()
	delete(s.rounds, source)
	close(round.done)
	s.mu.Unlock()
}

func (s *Service) cancelUnusedSourceLocked(source string) {
	for _, record := range s.state.Sessions {
		if record.SourceID == source && record.Status == "active" && s.opt.Now().Unix() < record.ExpiresAt {
			return
		}
	}
	if round := s.rounds[source]; round != nil {
		round.cancel()
	}
}

func (s *Service) queueNotificationLocked(record sessionRecord, event string) {
	key := record.ID + "\x00" + event
	if !s.availableLocked() || s.opt.Config.DryRun || s.notifications[key] {
		return
	}
	s.notifications[key] = true
	s.workers.Add(1)
	go func() {
		defer s.workers.Done()
		s.notify(record, event)
		s.mu.Lock()
		delete(s.notifications, key)
		s.mu.Unlock()
	}()
}

func (s *Service) Close() {
	s.mu.Lock()
	s.closed = true
	s.cancel()
	s.mu.Unlock()
	s.workers.Wait()
}

// Sampling deadlines are stored per session; this interval only controls due/lease scans.
func (s *Service) scanInterval(interval time.Duration) time.Duration {
	if interval <= 0 || interval > time.Second {
		return time.Second
	}
	return interval
}
