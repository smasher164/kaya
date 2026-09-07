# The WinUI search control, measured (docs/search-plan.md §7)

The two readings the plan asked for before the WinUI arm was chosen, plus
three the arm needed either way. Taken 2026-09-06 on the lane's own VM:
Windows 11 build 10.0.26200.9168 arm64, Windows App SDK / WinUI 3 **2.2.0**
(the runtime tools/deploy-win.py installs; the metadata tools/winui-bindgen
reads is the WinUI 2.2.1 package), .NET SDK 10, one 1280x800 display at
dpi 96.

The probe is `tools/win/searchprobe/`: an unpackaged WinUI 3 app
(`WindowsPackageType=None`, the shape kaya's own backend runs in), built on
the guest with `dotnet build`, launched in the interactive session through
`schtasks /it` and driving itself with real `keybd_event` keystrokes. Run it
with `tools/win/searchprobe/run.py akhil@192.168.64.2 --build`.

## A probe artifact, first, because it will bite the next person

A WinUI 3 app with **no XAML markup at all** gets no generated
`IXamlMetadataProvider`, and `new XamlControlsResources()` then throws

    COMException: Unspecified error
    Cannot find a resource with the given key: AcrylicBackgroundFillColorDefaultBrush.

and the window dies on `Activate()`. Copying kaya's
guests/assets/win/minimal-resources.pri beside the exe does **not** fix it:
that index answers the ms-appx half, not the metadata half. The fix is one
`App.xaml` carrying `x:Class` — the XAML compiler then emits the provider.
kaya's own backend composes the provider in Rust (crates/kaya/src/winui/mod.rs,
`outer_get_xaml_type`), which is why its guests merge the dictionary and a
markup-free probe does not. docs/probes/dnd-probe-windows-2026-09-03.md hit
the same wall and worked around it by using only `Border`s.

## 1. The empty flyout: it never opens

An `AutoSuggestBox` with `QueryIcon=Find` and **no `ItemsSource`**, three real
keystrokes, watched on the UI thread without blocking it:

    before typing: samples=16 maxOpenPopups=0 listOpenSamples=0 popups=[]
    asb TextChanged reason=UserInput text="a" listOpen=False
    after 'a': text="a" samples=34 maxOpenPopups=0 listOpenSamples=0 popups=[]
    asb TextChanged reason=UserInput text="an" listOpen=False
    after 'n': text="an" samples=35 maxOpenPopups=0 listOpenSamples=0 popups=[]
    asb TextChanged reason=UserInput text="ang" listOpen=False
    after 'g': text="ang" samples=35 maxOpenPopups=0 listOpenSamples=0 popups=[]
    asb TextChanged reason=ProgrammaticChange text="ch" listOpen=False
    after programmatic write: samples=23 maxOpenPopups=0 listOpenSamples=0 popups=[]

`IsSuggestionListOpen` was false and `VisualTreeHelper.GetOpenPopupsForXamlRoot`
counted zero open popups at every one of 143 samples, 15 ms apart, spanning
every keystroke and the write. The template's `Popup #SuggestionsPopup` never
opens.

The same run settles S6 both ways: **one `TextChanged` per keystroke**, no
coalescing, with `Reason=UserInput`, and `Reason=ProgrammaticChange` for a
property write — the discrimination the arm reads.

A METHOD NOTE, because the first run measured nothing and looked like it had:
its watcher polled with `Thread.Sleep` ON THE UI THREAD, which stops message
dispatch, so the injected keys sat in the queue and arrived appended to the
later programmatic write (`text="chang"`). `await Task.Delay` is the fix.

## 2. The peer: `AutoSuggestBox` reports `Group`, a `TextBox` reports `Edit`

    PEER AutoSuggestBox: controlType=Group className=AutoSuggestBox localized="group" name="" valuePattern=False invokePattern=True
    PEER AutoSuggestBox child: controlType=Edit className=TextBox name="Search"
    PEER AutoSuggestBox.innerTextBox: controlType=Edit className=TextBox localized="edit" name="Search"
    PEER TextBox: controlType=Edit className=TextBox localized="edit" name="Search"

crates/kaya/src/winui/mod.rs's `ax_role` maps `Group` to `group` and `Edit` to
`field`, so `expect_ax search@find` on an AutoSuggestBox reads `group/…`.
docs/search-plan.md S7 wants `field` on all five lanes.

## 3. A plain `TextBox` already carries the platform's clear button

Its template holds `Button #DeleteButton`, collapsed while the box is empty
or unfocused. The AutoSuggestBox's clear button is that same part on its inner
TextBox; the AutoSuggestBox adds only a trailing `Button #QueryButton` beside
it, which is a SUBMIT affordance — and docs/search-plan.md S4 refused submit.

    Grid #LayoutRoot
      TextBox #TextBox
        Grid
          Border #BorderElement
          ScrollViewer #ContentElement …
          ContentControl #PlaceholderTextContentPresenter
          Button #DeleteButton vis=Visible
          Button #QueryButton vis=Visible
            SymbolIcon
          ContentPresenter #DescriptionPresenter
      Popup #SuggestionsPopup

## 4. Invoking that button clears the text, keeps the focus, reads as a user edit

    DeleteButton invoke provider: True
    asb TextChanged reason=UserInput text="" listOpen=False
    after Invoke: asb.Text="" changes=[UserInput=""] focusedIsAsb=True

Which is exactly S5's sentence, published by the platform rather than
simulated by kaya.

## 5. Escape: an AutoSuggestBox swallows it; a TextBox does not

    asb after Escape: "an" focusedIsAsb=True changes=[UserInput="an"]
    keys the handlers saw: [asb.PreviewKeyDown Escape handled=False | asb.AddHandler(true) Escape handled=True]

    tb after Escape: "an" changes=["an", "an"]
    keys the handlers saw: [tb.KeyDown Escape handled=False | tb.AddHandler(true) Escape handled=False]

The ordinary `KeyDown` event — the only registration a WinRT delegate can make
from these bindings, since `AddHandler`'s handled-events-too overload wants an
`IInspectable` (docs/slider-plan.md §6) — never fires for Escape on an
AutoSuggestBox and does fire on a TextBox. Neither control clears itself on
Escape, so kaya's arm has to.

## The ruling: WinUI lowers `search` to a `TextBox`

The flyout never opens, which was the plan's stated condition for choosing
AutoSuggestBox — and the control is still refused, on four grounds the same
probe measured:

1. its peer says `Group`, so S7's `field` is unreachable without kaya
   asserting an identity the platform does not publish for the control kaya
   created;
2. it swallows Escape from the only handler these bindings can register, so
   S5's Escape arm is unreachable there;
3. it is not a `TextBox`, so it cannot be a `winui::Editable` — the entry's
   whole text contract would have to reach through a visual-tree walk into
   its template's inner TextBox;
4. the one thing it was wanted for, the platform's own clear affordance, a
   plain `TextBox` already has.

So the WinUI search field is a `TextBox` — the platform's own `DeleteButton`
as the clear affordance (driven through `ButtonAutomationPeer` /
`IInvokeProvider` by both `clear_search` and the Escape handler, which is
S5's one path), `PlaceholderText` as the prompt, and kaya's own Segoe Fluent
Find glyph (U+E721) overlaid in the leading slot, out of the assistive tree.
`AutoSuggestBox` is not in tools/winui-bindgen's filter.
