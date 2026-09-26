// The chat app (docs/chat-plan.md C0): a list of conversations beside a
// thread, messages as filled bubbles, a compose field that sends on
// Return, and a scripted peer that answers over a real socket on the
// loopback interface. The app's own model holds every conversation; an
// opened thread is a fresh collection filled from it.
package chat

import (
	"bufio"
	"fmt"
	"net"
	"strings"
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
type Theirs struct{ Text string }
type Reply struct {
	Quote string
	Text  string
}

func (Mine) isMessage()   {}
func (Theirs) isMessage() {}
func (Reply) isMessage()  {}

type message struct {
	key, text, quote string
	mine             bool
}

type conversation struct {
	id, name    string
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
		refresh := func(tx *kaya.Tx, c *conversation) {
			last := c.messages[len(c.messages)-1]
			list.Update(tx, c.id, Conversation{Name: c.name, Preview: last.text, Unread: unreadText(c)})
		}
		insert := func(tx *kaya.Tx, m message) {
			switch {
			case m.mine:
				thread.Insert(tx, m.key, Mine{Text: m.text})
			case m.quote != "":
				thread.Insert(tx, m.key, Reply{Quote: quoteOf(convs[open], m.quote), Text: m.text})
			default:
				thread.Insert(tx, m.key, Theirs{Text: m.text})
			}
		}

		peer.receive = func(tx *kaya.Tx, id, key, text string) {
			c := convs[id]
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
				c.messages = append(c.messages, m)
				insert(tx, m)
				tx.ScrollToRow(threadList, m.key)
				tx.SetText(compose, "")
				refresh(tx, c)
				peer.send(id, text)
			}
			draft := ""
			pane := tx.Column(func() {
				tx.Button("Newest", func(tx *kaya.Tx) {
					tx.ScrollToRow(threadList, c.messages[len(c.messages)-1].key)
				}).Role(kaya.RolePlain).A11yID("newest")
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
					)
					tx.SetA11yID(threadList, "thread")
				}).Grow(1).FollowsEnd()
				tx.Row(func() {
					// The compose field: one line at rest, growing with the message
					// to five (docs/grow-lines-plan.md); Return sends and
					// Shift+Return breaks the line.
					compose = tx.Textarea(func(tx *kaya.Tx, text string) { draft = text }).
						Submits().MaxLines(5).Placeholder("Message").A11yID("compose").Grow(1).
						OnSubmitted(send)
					tx.Button("Send", func(tx *kaya.Tx) { send(tx, draft) }).A11yID("send")
				})
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
			refresh(tx, c)
		}

		tx.Mount(tx.Column(func() {
			for row := range ConversationRows(tx, list).All() {
				row.Row(func() {
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
	maya := &conversation{id: "maya", name: "Maya"}
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
	sam := &conversation{id: "sam", name: "Sam", messages: []message{
		{key: "s1", text: "Did the build go out?"},
		{key: "s2", text: "Yesterday evening", mine: true},
		{key: "s3", text: "Great, thanks"},
	}, unread: 1, firstUnread: "s3"}
	alex := &conversation{id: "alex", name: "Alex", messages: []message{
		{key: "a1", text: "Photos from the trip"},
		{key: "a2", text: "These are lovely", mine: true},
	}}
	return map[string]*conversation{"maya": maya, "sam": sam, "alex": alex}
}

// The scripted peer, served on the loopback interface in this process and
// reached through the language's own network stack (docs/chat-plan.md §0).
// The wire is one tab-separated line per message.
type peer struct {
	conn    net.Conn
	receive func(tx *kaya.Tx, conv, key, text string)
}

// Each answer is (conversation, text, delay after the one before). Maya's
// second answer comes late enough for a reader to have scrolled away.
var script = map[string][][3]string{
	"maya": {{"maya", "See you soon", "200ms"}, {"sam", "Are we still on for Friday?", "0s"},
		{"maya", "Also, bring the umbrella", "2500ms"}},
	"sam":  {{"sam", "Perfect", "200ms"}},
	"alex": {{"alex", "Glad you liked them", "200ms"}},
}

func (p *peer) send(conv, text string) {
	fmt.Fprintf(p.conn, "SEND\t%s\t%s\n", conv, text)
}

func dialPeer(app *kaya.App, convs map[string]*conversation, order []string) *peer {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(fmt.Sprintf("chat: the peer could not listen on loopback: %v", err))
	}
	go serve(listener)
	conn, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		panic(fmt.Sprintf("chat: could not reach the peer at %s: %v", listener.Addr(), err))
	}
	p := &peer{conn: conn}
	go func() {
		lines := bufio.NewScanner(conn)
		for lines.Scan() {
			parts := strings.SplitN(lines.Text(), "\t", 4)
			if len(parts) != 4 || parts[0] != "MSG" {
				continue
			}
			conv, key, text := parts[1], parts[2], parts[3]
			app.Post(func(tx *kaya.Tx) {
				if p.receive != nil {
					p.receive(tx, conv, key, text)
				}
			})
		}
	}()
	return p
}

func serve(listener net.Listener) {
	conn, err := listener.Accept()
	if err != nil {
		return
	}
	seq := 0
	lines := bufio.NewScanner(conn)
	for lines.Scan() {
		parts := strings.SplitN(lines.Text(), "\t", 3)
		if len(parts) != 3 || parts[0] != "SEND" {
			continue
		}
		for _, answer := range script[parts[1]] {
			delay, _ := time.ParseDuration(answer[2])
			time.Sleep(delay)
			seq++
			fmt.Fprintf(conn, "MSG\t%s\tp%d\t%s\n", answer[0], seq, answer[1])
		}
	}
}
