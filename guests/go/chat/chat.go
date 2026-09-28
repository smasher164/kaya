// The chat app (docs/chat-plan.md C0): a list of conversations beside a
// thread, messages as filled bubbles, a compose field that sends on
// Return, and a scripted peer that answers over a real socket on the
// loopback interface. The app's own model holds every conversation; an
// opened thread is a fresh collection filled from it.
package chat

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Conversation -key string
type Conversation struct {
	Name    string
	Preview string
	Unread  string
}

//go:generate go run dev.kaya/cmd/kaya-gen -type Message -key string
type Message interface{ isMessage() }

type Mine struct{ Text string }
type Pending struct{ Text string }
type Theirs struct{ Text string }
type Reply struct {
	Quote string
	Text  string
}
type Photo struct{ Image []byte }

func (Mine) isMessage()    {}
func (Pending) isMessage() {}
func (Theirs) isMessage() {}
func (Reply) isMessage()  {}
func (Photo) isMessage()  {}

type message struct {
	key, text, quote string
	mine, queued     bool
	photo            []byte
}

type conversation struct {
	id, name    string
	note        uint64
	messages    []message
	unread      int
	firstUnread string
}

const threadEntry = 1

func App() *kaya.App {
	app := kaya.NewApp()
	convs := seed()
	order := []string{"maya", "sam", "alex"}
	peer := dialPeer(app, convs, order)

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("chat").Size(900, 640).Panes(2)
		list := ConversationCollection(tx)

		// The open thread: which conversation, its collection and its For.
		var open string
		var thread kaya.SumCollection[string, Message]
		var threadList kaya.Widget
		sent := 0

		unreadText := func(c *conversation) string {
			if c.unread == 0 {
				return ""
			}
			return fmt.Sprintf("%d new", c.unread)
		}
		unreadTotal := func() uint32 {
			total := 0
			for _, c := range convs {
				total += c.unread
			}
			return uint32(total)
		}
		refresh := func(tx *kaya.Tx, c *conversation) {
			last := c.messages[len(c.messages)-1]
			list.Update(tx, c.id, Conversation{Name: c.name, Preview: last.text, Unread: unreadText(c)})
		}
		insert := func(tx *kaya.Tx, m message) {
			switch {
			case m.photo != nil:
				thread.Insert(tx, m.key, Photo{Image: m.photo})
			case m.queued:
				thread.Insert(tx, m.key, Pending{Text: m.text})
			case m.mine:
				thread.Insert(tx, m.key, Mine{Text: m.text})
			case m.quote != "":
				thread.Insert(tx, m.key, Reply{Quote: quoteOf(convs[open], m.quote), Text: m.text})
			default:
				thread.Insert(tx, m.key, Theirs{Text: m.text})
			}
		}

		connection := tx.Signal("")
		peer.online = func(tx *kaya.Tx, online bool) {
			if !online {
				tx.Write(connection, "Offline")
				return
			}
			tx.Write(connection, "")
			for _, c := range convs {
				for i := range c.messages {
					m := &c.messages[i]
					if m.queued {
						m.queued = false
						if c.id == open {
							thread.Update(tx, m.key, Mine{Text: m.text})
						}
					}
				}
			}
		}

		peer.receive = func(tx *kaya.Tx, id, key, text string) {
			c := convs[id]
			if c == nil {
				return
			}
			c.messages = append(c.messages, message{key: key, text: text})
			if id == open {
				// The thread's scroll follows its end (docs/follow-end-plan.md):
				// the reply shows when the reader was at the newest message and
				// leaves them where they are when they were not.
				insert(tx, c.messages[len(c.messages)-1])
			} else {
				if c.unread == 0 {
					c.firstUnread = key
				}
				c.unread++
				tx.SetBadge(unreadTotal())
				tx.ShowNotification(c.note).Title(c.name).Body(text).Reply("Message").Show()
			}
			refresh(tx, c)
		}

		openThread := func(tx *kaya.Tx, id string) {
			c := convs[id]
			if open != "" {
				tx.PopEntry()
			}
			open = id
			entry := tx.PushEntry(threadEntry).
				Title(c.name).
				OnPopped(func(tx *kaya.Tx) { open = "" }).
				Id()
			var compose kaya.Widget
			send := func(tx *kaya.Tx, text string) {
				text = strings.TrimSpace(text)
				if text == "" {
					return
				}
				sent++
				m := message{key: fmt.Sprintf("u%d", sent), text: text, mine: true}
				m.queued = !peer.send(id, text)
				c.messages = append(c.messages, m)
				insert(tx, m)
				tx.ScrollToRow(threadList, m.key)
				tx.SetText(compose, "")
				refresh(tx, c)
			}
			// A photo is the user's own message, shown in the thread; the
			// scripted peer answers text only (docs/photo-attach-plan.md §5).
			sendPhoto := func(tx *kaya.Tx, photo []byte) {
				sent++
				m := message{key: fmt.Sprintf("u%d", sent), text: "Photo", mine: true, photo: photo}
				c.messages = append(c.messages, m)
				insert(tx, m)
				tx.ScrollToRow(threadList, m.key)
				refresh(tx, c)
			}
			attach := func(tx *kaya.Tx) {
				tx.PickFile().Content(kaya.FileContentImages).OnResult(func(tx *kaya.Tx, files []kaya.PickedFile) {
					if len(files) == 0 {
						return
					}
					// Opening a picked file may block while a provider fetches
					// it, so the read happens off the app thread.
					go func(file kaya.PickedFile) {
						f, _, err := file.Open(kaya.FileModeRead)
						if err != nil {
							return
						}
						photo, err := io.ReadAll(f)
						f.Close()
						if err != nil || len(photo) == 0 {
							return
						}
						app.Post(func(tx *kaya.Tx) { sendPhoto(tx, photo) })
					}(files[0])
				}).Show()
			}
			draft := ""
			var found []string
			at := -1
			matches := tx.Signal("")
			pane := tx.Column(func() {
				tx.Row(func() {
					tx.Search(func(tx *kaya.Tx, text string) {
						query := strings.ToLower(strings.TrimSpace(text))
						found, at = nil, -1
						for i := len(c.messages) - 1; i >= 0 && query != ""; i-- {
							if strings.Contains(strings.ToLower(c.messages[i].text), query) {
								found = append(found, c.messages[i].key)
							}
						}
						switch {
						case query == "":
							tx.Write(matches, "")
						case len(found) == 1:
							tx.Write(matches, "1 match")
						default:
							tx.Write(matches, fmt.Sprintf("%d matches", len(found)))
						}
					}).Placeholder("Search").A11yID("find").Grow(1).
						OnSubmitted(func(tx *kaya.Tx, text string) {
							if len(found) == 0 {
								return
							}
							at = (at + 1) % len(found)
							tx.ScrollToRow(threadList, found[at])
							tx.Write(matches, fmt.Sprintf("%d of %d", at+1, len(found)))
						})
					tx.Label(matches).A11yID("matches")
				})
				tx.Row(func() {
					tx.Button("Newest", func(tx *kaya.Tx) {
						tx.ScrollToRow(threadList, c.messages[len(c.messages)-1].key)
					}).Role(kaya.RolePlain).A11yID("newest")
					tx.Spacer()
					tx.Label(connection).A11yID("connection")
				})
				tx.Scroll(func() {
					thread = MessageCollection(tx)
					threadList = MessageEachSum(tx, thread,
						func(mine kaya.SumCase[string, Mine]) {
							mine.Row(func() {
								mine.Spacer()
								bubble := mine.Column(func() {
									text := mine.Label(func(m *Mine) *string { return &m.Text })
									mine.SetA11yID(text, "text")
								})
								mine.SetFilled(bubble, kaya.TintAccent)
							})
						},
						func(pending kaya.SumCase[string, Pending]) {
							pending.Row(func() {
								pending.Spacer()
								bubble := pending.Column(func() {
									text := pending.Label(func(m *Pending) *string { return &m.Text })
									pending.SetA11yID(text, "text")
									state := pending.CaptionText("Sending…")
									pending.SetA11yID(state, "state")
								})
								pending.SetFilled(bubble, kaya.TintAccent)
							})
						},
						func(theirs kaya.SumCase[string, Theirs]) {
							theirs.Row(func() {
								bubble := theirs.Column(func() {
									text := theirs.Label(func(m *Theirs) *string { return &m.Text })
									theirs.SetA11yID(text, "text")
								})
								theirs.SetFilled(bubble, kaya.TintNeutral)
								theirs.Spacer()
							})
						},
						func(reply kaya.SumCase[string, Reply]) {
							reply.Row(func() {
								bubble := reply.Column(func() {
									quote := reply.ButtonBound(func(m *Reply) *string { return &m.Quote },
										func(tx *kaya.Tx, key string) {
											for _, m := range c.messages {
												if m.key == key {
													tx.ScrollToRow(threadList, m.quote)
												}
											}
										})
									reply.SetA11yID(quote, "quote")
									reply.SetRole(quote, kaya.RolePlain)
									text := reply.Label(func(m *Reply) *string { return &m.Text })
									reply.SetA11yID(text, "text")
								})
								reply.SetFilled(bubble, kaya.TintNeutral)
								reply.Spacer()
							})
						},
						func(photo kaya.SumCase[string, Photo]) {
							photo.Row(func() {
								photo.Spacer()
								image := photo.Image(func(m *Photo) *[]byte { return &m.Image })
								photo.SetA11yID(image, "photo")
								photo.SetMaxWidth(image, 240)
								photo.SetMaxHeight(image, 240)
							})
						},
					)
					tx.SetA11yID(threadList, "thread")
				}).Grow(1).FollowsEnd()
				tx.Row(func() {
					// The compose field: one line at rest, growing with the message
					// to five (docs/grow-lines-plan.md); Return sends and
					// Shift+Return breaks the line. The composer draws the field
					// and its emoji button as one (docs/composer-plan.md), with the
					// attach button before it, as Messages places its own.
					tx.Button("Attach", attach).Symbol(kaya.SymbolAttach).A11yID("attach")
					tx.Row(func() {
						compose = tx.Textarea(func(tx *kaya.Tx, text string) { draft = text }).
							Submits().MaxLines(5).Placeholder("Message").A11yID("compose").Grow(1).
							OnSubmitted(send)
						if kaya.Capabilities().EmojiPicker {
							tx.Button("Emoji", func(tx *kaya.Tx) { tx.ShowEmojiPicker(compose) }).
								Symbol(kaya.SymbolEmoji).A11yID("emoji")
						}
					}).Role(kaya.RoleComposer).Grow(1)
					tx.Button("Send", func(tx *kaya.Tx) { send(tx, draft) }).
						Symbol(kaya.SymbolSend).Role(kaya.RoleProminent).A11yID("send")
				}).Align(kaya.AlignEnd)
			})
			tx.MountIn(entry, pane)
			for _, m := range c.messages {
				insert(tx, m)
			}
			if c.firstUnread != "" {
				tx.ScrollToRow(threadList, c.firstUnread)
			} else {
				tx.ScrollToRow(threadList, c.messages[len(c.messages)-1].key)
			}
			c.unread, c.firstUnread = 0, ""
			tx.SetBadge(unreadTotal())
			tx.CancelNotification(c.note)
			refresh(tx, c)
		}

		// C4 (docs/notification-reply-plan.md): a reply from the notification
		// sends the text to that conversation and marks it read, without
		// opening it. Replies count on their own (r1, r2, ...), so the
		// messages typed in the app keep their keys whether or not this
		// platform could reply.
		replied := 0
		replyFrom := func(tx *kaya.Tx, c *conversation, text string) {
			text = strings.TrimSpace(text)
			if text == "" {
				return
			}
			replied++
			m := message{key: fmt.Sprintf("r%d", replied), text: text, mine: true}
			m.queued = !peer.send(c.id, text)
			c.messages = append(c.messages, m)
			if c.id == open {
				insert(tx, m)
			}
			c.unread, c.firstUnread = 0, ""
			tx.SetBadge(unreadTotal())
			refresh(tx, c)
		}

		app.OnNotificationActivation(func(tx *kaya.Tx, note uint64, result kaya.NotificationResult) {
			for _, c := range convs {
				if c.note != note {
					continue
				}
				switch result.Outcome {
				case kaya.NotificationOutcomeActivated:
					openThread(tx, c.id)
				case kaya.NotificationOutcomeReplied:
					replyFrom(tx, c, result.Text)
				}
			}
		})

		// C7 (docs/swipe-actions-plan.md): a conversation's actions are in its
		// row's context menu everywhere, and swipe the row where the platform
		// swipes rows.
		rowActions := tx.ContextCatalog()
		rowActions.Item("Mark unread").Swipe(kaya.SwipeLeading).
			OnActivateNode(func(tx *kaya.Tx, keys []any) {
				c := convs[keys[0].(string)]
				if c.unread == 0 {
					c.unread, c.firstUnread = 1, c.messages[len(c.messages)-1].key
					tx.SetBadge(unreadTotal())
					refresh(tx, c)
				}
			})
		rowActions.Item("Archive").Swipe(kaya.SwipeTrailingFull).
			OnActivateNode(func(tx *kaya.Tx, keys []any) {
				id := keys[0].(string)
				if id == open {
					tx.PopEntry()
					open = ""
				}
				list.Remove(tx, id)
				delete(convs, id)
				tx.SetBadge(unreadTotal())
			})

		tx.Mount(tx.Column(func() {
			for row := range ConversationRows(tx, list).All() {
				convo := row.Row(func() {
					row.Column(func() {
						name := row.Button(row.Name(), openThread)
						row.SetA11yID(name, "open")
						row.SetRole(name, kaya.RolePlain)
						preview := row.Caption(row.Preview())
						row.SetA11yID(preview, "preview")
					})
					row.Spacer()
					unread := row.Label(row.Unread())
					row.SetA11yID(unread, "unread")
				})
				row.SetA11yID(convo, "convo")
				row.ContextMenu(convo, rowActions)
			}
		}))
		for _, id := range order {
			c := convs[id]
			list.Insert(tx, id, Conversation{Name: c.name})
			refresh(tx, c)
		}
	})

	return app
}

func quoteOf(c *conversation, key string) string {
	for _, m := range c.messages {
		if m.key == key {
			// U+FE0E asks for the text glyph: iOS draws a bare ↩ as an emoji.
			return "↩\uFE0E " + m.text
		}
	}
	return "↩ (deleted)"
}

// seed is the synthetic history (docs/chat-plan.md §0): Maya's thread is
// long enough that its first unread message and the one it quotes sit far
// apart, which is what the thread's two jumps need.
func seed() map[string]*conversation {
	maya := &conversation{id: "maya", name: "Maya", note: 7001}
	lines := []string{
		"Are you around this week?", "Mostly, yes", "Dinner at 7 on Friday?",
		"Sounds good", "The usual place?", "Yes, the one on Pine",
	}
	for i := 1; i <= 26; i++ {
		maya.messages = append(maya.messages, message{
			key: fmt.Sprintf("m%02d", i), text: lines[(i-1)%len(lines)], mine: i%2 == 0,
		})
	}
	maya.messages = append(maya.messages,
		message{key: "m27", text: "Still good for this?", quote: "m03"},
		message{key: "m28", text: "I can bring dessert"},
		message{key: "m29", text: "Let me know"},
		message{key: "m30", text: "Running a little late"},
	)
	maya.unread, maya.firstUnread = 4, "m27"
	sam := &conversation{id: "sam", name: "Sam", note: 7002, messages: []message{
		{key: "s1", text: "Did the build go out?"},
		{key: "s2", text: "Yesterday evening", mine: true},
		{key: "s3", text: "Great, thanks"},
	}, unread: 1, firstUnread: "s3"}
	alex := &conversation{id: "alex", name: "Alex", note: 7003, messages: []message{
		{key: "a1", text: "Photos from the trip"},
		{key: "a2", text: "These are lovely", mine: true},
	}}
	return map[string]*conversation{"maya": maya, "sam": sam, "alex": alex}
}

// The scripted peer, served on the loopback interface in this process and
// reached through the language's own network stack (docs/chat-plan.md §0).
// The wire is one tab-separated line per message. A script line whose text
// is dropLine closes the connection and keeps the peer away for peerAway
// (C9): the app shows it is offline, queues what is sent meanwhile, redials
// and sends the queue once it is back.
type peer struct {
	app     *kaya.App
	addr    string
	mu      sync.Mutex
	conn    net.Conn
	queue   []string
	receive func(tx *kaya.Tx, conv, key, text string)
	online  func(tx *kaya.Tx, online bool)
}

const dropLine = "\x00drop"
const peerAway = 10 * time.Second

// Each answer is (conversation, text, delay after the one before). Maya's
// second answer comes late enough for a reader to have scrolled away, and
// Sam's first answer is followed by the connection dropping.
var script = map[string][][3]string{
	"maya": {{"maya", "See you soon", "200ms"}, {"sam", "Are we still on for Friday?", "0s"},
		{"alex", "Did the photos come through?", "0s"},
		{"maya", "Also, bring the umbrella", "2500ms"}},
	"sam":  {{"sam", "Perfect", "200ms"}, {"sam", dropLine, "0s"}},
	"alex": {{"alex", "Glad you liked them", "200ms"}},
}

// send writes the message, or queues it while the peer is away and says so.
func (p *peer) send(conv, text string) bool {
	line := fmt.Sprintf("SEND\t%s\t%s\n", conv, text)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.conn == nil {
		p.queue = append(p.queue, line)
		return false
	}
	fmt.Fprint(p.conn, line)
	return true
}

func dialPeer(app *kaya.App, convs map[string]*conversation, order []string) *peer {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(fmt.Sprintf("chat: the peer could not listen on loopback: %v", err))
	}
	p := &peer{app: app, addr: listener.Addr().String()}
	go serve(listener, p.addr)
	conn, err := net.Dial("tcp", p.addr)
	if err != nil {
		panic(fmt.Sprintf("chat: could not reach the peer at %s: %v", p.addr, err))
	}
	p.conn = conn
	go p.read(conn)
	return p
}

// read delivers the peer's messages until the connection ends, then redials
// until the peer is back and sends what was queued.
func (p *peer) read(conn net.Conn) {
	lines := bufio.NewScanner(conn)
	for lines.Scan() {
		parts := strings.SplitN(lines.Text(), "\t", 4)
		if len(parts) != 4 || parts[0] != "MSG" {
			continue
		}
		conv, key, text := parts[1], parts[2], parts[3]
		p.app.Post(func(tx *kaya.Tx) {
			if p.receive != nil {
				p.receive(tx, conv, key, text)
			}
		})
	}
	p.mu.Lock()
	p.conn = nil
	p.mu.Unlock()
	p.app.Post(func(tx *kaya.Tx) { p.online(tx, false) })
	for {
		time.Sleep(500 * time.Millisecond)
		next, err := net.Dial("tcp", p.addr)
		if err != nil {
			continue
		}
		p.mu.Lock()
		p.conn = next
		for _, line := range p.queue {
			fmt.Fprint(next, line)
		}
		p.queue = nil
		p.mu.Unlock()
		p.app.Post(func(tx *kaya.Tx) { p.online(tx, true) })
		go p.read(next)
		return
	}
}

// serve answers one connection at a time; the one drop closes the listener
// too, so the app's redials are refused until the peer is back on the same
// port.
// Each conversation numbers its peer's messages on its own (p1, p2, ... in
// every thread), so an answer to one conversation leaves another's keys
// where the scene expects them.
func serve(listener net.Listener, addr string) {
	seq := map[string]int{}
	away := false
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		dropped := false
		lines := bufio.NewScanner(conn)
		for !dropped && lines.Scan() {
			parts := strings.SplitN(lines.Text(), "\t", 3)
			if len(parts) != 3 || parts[0] != "SEND" {
				continue
			}
			for _, answer := range script[parts[1]] {
				delay, _ := time.ParseDuration(answer[2])
				time.Sleep(delay)
				if answer[1] == dropLine {
					if !away {
						dropped, away = true, true
						break
					}
					continue
				}
				seq[answer[0]]++
				fmt.Fprintf(conn, "MSG\t%s\tp%d\t%s\n", answer[0], seq[answer[0]], answer[1])
			}
		}
		conn.Close()
		if !dropped {
			return
		}
		listener.Close()
		time.Sleep(peerAway)
		listener, err = net.Listen("tcp", addr)
		if err != nil {
			panic(fmt.Sprintf("chat: the peer could not come back on %s: %v", addr, err))
		}
	}
}
