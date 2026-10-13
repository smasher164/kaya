// Network images (docs/network-images-plan.md): the image's phase, the
// conditional row write (N7), the two realization handlers (N8) and the
// row-image helper (N12). kaya fetches nothing; the app's fetch does.
package kaya

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"sync"
)

// ImagePhase is what an image shows while its bytes are not its picture
// yet: ImagePhaseShown, ImagePhaseLoading, ImagePhaseFailed (N2).
type ImagePhase int64

// SetPhase sets a live image's phase.
func (tx *Tx) SetPhase(w Widget, phase ImagePhase) { tx.emit(TxSetPhase(w.id, int64(phase))) }

// Phase is SetPhase's chain. A loading or failed image declares its box:
// MaxWidth, MaxHeight and Fit (N3).
func (w Widget) Phase(phase ImagePhase) Widget {
	w.tx.SetPhase(w, phase)
	return w
}

// BindPhase reads a live image's phase from a signal.
func (w Widget) BindPhase(s Signal[ImagePhase]) Widget {
	w.tx.emit(TxBindPhase(w.id, s.id))
	return w
}

// SetPhase sets every stamped copy's phase.
func (t *Tpl) SetPhase(n Node, phase ImagePhase) { t.tx.emit(TxSetPhase(n.id, int64(phase))) }

// BindPhase reads each stamped copy's phase from the row's field or a
// signal.
func (t *Tpl) BindPhase[S interface {
	Signal[ImagePhase] | Field[ImagePhase]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[ImagePhase]:
		t.tx.emit(TxBindPhase(n.id, v.id))
	case Field[ImagePhase]:
		t.tx.emit(TxBindPhaseElement(n.id, 0, v.index))
	}
}

// OnNeeded runs when a stamped copy of this image is realized loading
// with no source, once per row until OnReleased runs for it (N8). The
// handler receives the copy's keys, outermost first.
func (n Node) OnNeeded(fn func(*Tx, []any)) Node {
	n.tx.app.images.table().needed[n.id] = fn
	return n
}

// OnReleased runs when the last realized copy of a row this image was
// needed for is torn down while still loading.
func (n Node) OnReleased(fn func(*Tx, []any)) Node {
	n.tx.app.images.table().released[n.id] = fn
	return n
}

// FetchedBy hands this image's needed and released rows to a helper,
// before and whatever OnNeeded and OnReleased do.
func (n Node) FetchedBy(f ImageFeed) Node {
	t := n.tx.app.images.table()
	t.feeds[n.id] = append(t.feeds[n.id], f)
	return n
}

// ImageFeed is what FetchedBy takes: a RowImages.
type ImageFeed interface {
	imageNeeded(tx *Tx, keys []any)
	imageReleased(keys []any)
}

type imageState struct {
	needed   map[uint64]func(*Tx, []any)
	released map[uint64]func(*Tx, []any)
	feeds    map[uint64][]ImageFeed
}

func (s *imageState) table() *imageState {
	if s.needed == nil {
		s.needed = map[uint64]func(*Tx, []any){}
		s.released = map[uint64]func(*Tx, []any){}
		s.feeds = map[uint64][]ImageFeed{}
	}
	return s
}

func imageOccurrence(kind uint16) bool { return kind == occImageNeeded || kind == occImageReleased }

func (a *App) imageOccurred(kind uint16, node uint64, keys []any) {
	s := a.images.table()
	feeds := s.feeds[node]
	fn := s.needed[node]
	if kind == occImageReleased {
		fn = s.released[node]
	}
	if len(feeds) == 0 && fn == nil {
		return
	}
	a.dispatch(func(tx *Tx) {
		for _, f := range feeds {
			if kind == occImageNeeded {
				f.imageNeeded(tx, keys)
			} else {
				f.imageReleased(keys)
			}
		}
		if fn != nil {
			fn(tx, keys)
		}
	})
}

// RecordPatchIf is RecordPatch with a guard: its writes are made only
// while the row exists and the guard's field still holds the value it
// names, otherwise nothing, and no panic (N7). The chain is ONE record,
// sent when the transaction's next record is, or when it ends.
type RecordPatchIf[K Key, T any] struct {
	c RecordCollection[K, T]
	p *pendingPatchIf
}

type pendingPatchIf struct {
	tx     *Tx
	coll   uint64
	path   []any
	key    any
	field  uint32
	guard  any
	fields []any
	values []any
	holds  bool
}

// PatchIf opens a guarded patch on one entry:
// TrackPatchIf(tracks, tx, key, func(t *Track) *string { return &t.ArtURL }, url).Art(b).
func (c RecordCollection[K, T]) PatchIf[V comparable](tx *Tx, key K, guard func(*T) *V, expected V) RecordPatchIf[K, T] {
	return c.PatchIfAt(tx, key, FieldBy(guard), expected)
}

// PatchIfAt is PatchIf over a pre-resolved token.
func (c RecordCollection[K, T]) PatchIfAt[V comparable](tx *Tx, key K, guard Field[V], expected V) RecordPatchIf[K, T] {
	tx.flushPatchIf()
	tx.alive()
	holds := false
	if record, ok := c.entry(tx, key); ok {
		held := reflect.ValueOf(record).Field(c.info.indexes[guard.index]).Interface()
		holds = held == any(expected)
	}
	p := &pendingPatchIf{
		tx: tx, coll: c.coll.id, path: append([]any(nil), c.coll.path...), key: key,
		field: guard.index, guard: c.info.encode(guard.index, expected), holds: holds,
	}
	tx.pendingIf = p
	return RecordPatchIf[K, T]{c, p}
}

func (c RecordCollection[K, T]) entry(tx *Tx, key K) (T, bool) {
	var zero T
	in := tx.app.instanceOf(c.coll.id, c.coll.path)
	if in == nil {
		return zero, false
	}
	for _, e := range in.entries {
		if e.Key == any(key) {
			return e.Value.(T), true
		}
	}
	return zero, false
}

// Set writes the field the projection selects when the guard holds;
// chainable within the one statement.
func (p RecordPatchIf[K, T]) Set[V any](project func(*T) *V, value V) RecordPatchIf[K, T] {
	return p.SetAt(FieldBy(project), value)
}

// SetAt is Set over a pre-resolved token.
func (p RecordPatchIf[K, T]) SetAt[V any](f Field[V], value V) RecordPatchIf[K, T] {
	if p.p == nil || p.p.tx.pendingIf != p.p {
		panic("kaya: a PatchIf chain is one statement — its record was already sent " +
			"when the transaction's next record was; chain every Set on the PatchIf call")
	}
	p.p.tx.alive()
	p.p.fields = append(p.p.fields, int64(f.index))
	p.p.values = append(p.p.values, p.c.info.encode(f.index, value))
	if p.p.holds {
		record, _ := p.c.entry(p.p.tx, p.p.key.(K))
		rv := reflect.ValueOf(&record).Elem()
		rv.Field(p.c.info.indexes[f.index]).Set(reflect.ValueOf(value))
		p.p.tx.app.modelSet(p.c.coll.id, p.c.coll.path, p.p.key, record)
	}
	return p
}

// flushPatchIf sends a pending guarded patch: through emit, before the
// record that follows it, and at the end of Build.
func (tx *Tx) flushPatchIf() {
	p := tx.pendingIf
	if p == nil {
		return
	}
	tx.pendingIf = nil
	tx.emit(TxCollectionPatchIf(p.coll, p.path, p.key, p.field, 0, p.guard, p.fields, p.values))
	if p.holds {
		tx.recomputeDerived(p.coll, p.path)
	}
}

// Fetch is the app's fetch: the bytes at a URL, or why not. It stops
// when ctx is cancelled, which RowImages does once no row waits on it.
type Fetch func(ctx context.Context, url string) ([]byte, error)

// FetchHTTP is the default Fetch, net/http's GET; a status outside 2xx
// is an error.
func FetchHTTP(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("%s answered %s", url, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// RowImages loads a row's image on demand (N12): each row holds the URL
// it wants, its bytes and its phase; a row realized loading with no
// bytes is fetched, at most RowImagesLimit at a time, rows sharing a URL
// share one fetch, and every result is one PatchIf guarded on the URL.
type RowImages[K Key, T any] struct {
	app     *App
	rows    RecordCollection[K, T]
	url     Field[string]
	art     Field[[]byte]
	phase   Field[ImagePhase]
	fetch   Fetch
	onError func(*Tx, []any, error)
	key     func(any) any

	mu      sync.Mutex
	queue   []*imageJob
	jobs    map[string]*imageJob
	workers int
	cache   imageCache
}

// RowImagesLimit is how many fetches RowImages runs at once.
const RowImagesLimit = 6

type imageJob struct {
	url     string
	waiting [][]any
	cancel  context.CancelFunc
}

// NewRowImages loads the art of rows, the root handle of the collection
// the template image's For stamps; fetch nil is FetchHTTP. Attach it with
// the template image's FetchedBy.
func NewRowImages[K Key, T any](app *App, rows RecordCollection[K, T],
	url func(*T) *string, art func(*T) *[]byte, phase func(*T) *ImagePhase, fetch Fetch,
) *RowImages[K, T] {
	if fetch == nil {
		fetch = FetchHTTP
	}
	return &RowImages[K, T]{
		app: app, rows: rows,
		url: FieldBy(url), art: FieldBy(art), phase: FieldBy(phase),
		fetch: fetch, key: restoreKey[K](), jobs: map[string]*imageJob{},
	}
}

// OnError runs on the app thread inside the transaction that writes
// ImagePhaseFailed, with the row's keys and the fetch's error.
func (r *RowImages[K, T]) OnError(fn func(tx *Tx, keys []any, err error)) *RowImages[K, T] {
	r.onError = fn
	return r
}

func (r *RowImages[K, T]) instance(keys []any) (RecordCollection[K, T], K, bool) {
	var zero K
	if len(keys) == 0 {
		return r.rows, zero, false
	}
	c := r.rows
	for _, k := range keys[:len(keys)-1] {
		c = c.At(k)
	}
	key, ok := r.key(keys[len(keys)-1]).(K)
	return c, key, ok
}

func (r *RowImages[K, T]) imageNeeded(tx *Tx, keys []any) {
	c, key, ok := r.instance(keys)
	if !ok {
		return
	}
	record, ok := c.entry(tx, key)
	if !ok {
		return
	}
	url := reflect.ValueOf(record).Field(c.info.indexes[r.url.index]).String()
	if url == "" {
		return
	}
	r.mu.Lock()
	if bytes, hit := r.cache.get(url); hit {
		r.mu.Unlock()
		r.write(tx, [][]any{keys}, url, bytes, nil)
		return
	}
	if job := r.jobs[url]; job != nil {
		job.waiting = append(job.waiting, keys)
		r.mu.Unlock()
		return
	}
	job := &imageJob{url: url, waiting: [][]any{keys}}
	r.jobs[url] = job
	r.queue = append(r.queue, job)
	start := r.workers < RowImagesLimit
	if start {
		r.workers++
	}
	r.mu.Unlock()
	if start {
		go r.work()
	}
}

// imageReleased: a released row stops waiting; a URL nobody waits on is
// taken off the queue, or its running fetch cancelled.
func (r *RowImages[K, T]) imageReleased(keys []any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for url, job := range r.jobs {
		kept := job.waiting[:0]
		for _, w := range job.waiting {
			if !pathEq(w, keys) {
				kept = append(kept, w)
			}
		}
		job.waiting = kept
		if len(kept) > 0 {
			continue
		}
		delete(r.jobs, url)
		if job.cancel != nil {
			job.cancel()
			continue
		}
		for i, q := range r.queue {
			if q == job {
				r.queue = append(r.queue[:i], r.queue[i+1:]...)
				break
			}
		}
	}
}

func (r *RowImages[K, T]) work() {
	for {
		r.mu.Lock()
		if len(r.queue) == 0 {
			r.workers--
			r.mu.Unlock()
			return
		}
		job := r.queue[0]
		r.queue = r.queue[1:]
		ctx, cancel := context.WithCancel(context.Background())
		job.cancel = cancel
		r.mu.Unlock()

		bytes, err := r.fetch(ctx, job.url)
		cancel()

		r.mu.Lock()
		if err == nil {
			r.cache.put(job.url, bytes)
		}
		if r.jobs[job.url] == job {
			delete(r.jobs, job.url)
		}
		rows := job.waiting
		job.waiting = nil
		r.mu.Unlock()
		if len(rows) > 0 {
			r.app.Post(func(tx *Tx) { r.write(tx, rows, job.url, bytes, err) })
		}
	}
}

func (r *RowImages[K, T]) write(tx *Tx, rows [][]any, url string, bytes []byte, err error) {
	for _, keys := range rows {
		c, key, ok := r.instance(keys)
		if !ok {
			continue
		}
		p := c.PatchIfAt(tx, key, r.url, url)
		if err == nil {
			p.SetAt(r.art, bytes).SetAt(r.phase, ImagePhaseShown)
			continue
		}
		p.SetAt(r.phase, ImagePhaseFailed)
		if r.onError != nil {
			r.onError(tx, keys, err)
		}
	}
}

// imageCache is the encoded bytes by URL, least recently used out past
// 32 MB.
type imageCache struct {
	entries map[string]*imageCacheEntry
	bytes   int
	tick    uint64
}

type imageCacheEntry struct {
	data []byte
	used uint64
}

const imageCacheBudget = 32 << 20

func (c *imageCache) get(url string) ([]byte, bool) {
	c.tick++
	e, ok := c.entries[url]
	if !ok {
		return nil, false
	}
	e.used = c.tick
	return e.data, true
}

func (c *imageCache) put(url string, data []byte) {
	if c.entries == nil {
		c.entries = map[string]*imageCacheEntry{}
	}
	c.tick++
	if old, ok := c.entries[url]; ok {
		c.bytes -= len(old.data)
	}
	c.entries[url] = &imageCacheEntry{data: data, used: c.tick}
	c.bytes += len(data)
	for c.bytes > imageCacheBudget && len(c.entries) > 1 {
		oldest, at := "", ^uint64(0)
		for u, e := range c.entries {
			if e.used < at {
				oldest, at = u, e.used
			}
		}
		c.bytes -= len(c.entries[oldest].data)
		delete(c.entries, oldest)
	}
}
