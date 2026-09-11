// The UIA3 COM client half of the rich-text probe (docs/rich-text-plan.md R9).
//
// WHY IT EXISTS: the managed System.Windows.Automation client (uia.ps1) has no
// AutomationTextAttribute for the ids that decide the ruling - Link (40035),
// StyleName (40033), StyleId (40034), AnnotationTypes (40031) - LookupById
// answers null for all four; and the WinUI RichEditBox's XAML automation peer
// has no ITextProvider to ask in process (both measured, runs 2 and 3). So the
// numeric ids are asked of UIAutomationCore directly.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using Interop.UIAutomationClient;

static class Uia3
{
    const int AutomationIdProperty = 30011;
    const int ProcessIdProperty = 30005;
    const int TextPatternId = 10014;

    static readonly int[] Ids =
    {
        40005, 40006, 40007, 40008, 40013, 40014, 40026, 40030,
        40031, 40033, 40034, 40035, 40036, 40038
    };
    static readonly string[] Names =
    {
        "FontName", "FontSize", "FontWeight", "ForegroundColor", "IsHidden", "IsItalic",
        "StrikethroughStyle", "UnderlineStyle", "AnnotationTypes", "StyleName", "StyleId",
        "Link", "IsActive", "CaretPosition"
    };

    static IUIAutomation A;

    static string Val(object v)
    {
        if (v == null) return "<null>";
        if (ReferenceEquals(v, A.ReservedNotSupportedValue)) return "NotSupported";
        if (ReferenceEquals(v, A.ReservedMixedAttributeValue)) return "Mixed";
        if (v is IUIAutomationTextRange)
        {
            var r = (IUIAutomationTextRange)v;
            return "TextRange[" + Esc(r.GetText(-1)) + "]";
        }
        if (v is IUIAutomationElement)
            return "Element[" + ((IUIAutomationElement)v).CurrentName + "]";
        return v.ToString();
    }

    static string Esc(string s)
    {
        if (s == null) return "<null>";
        return s.Replace("\r", "\\r").Replace("\n", "\\n");
    }

    static void Main()
    {
        var log = new StringBuilder();
        Action<string> Say = t => { log.AppendLine(t); Console.WriteLine(t); };
        try
        {
            int pid = int.Parse(File.ReadAllText(@"C:\kaya\richtext-probe\pid.txt").Trim());
            Say("uia3: probe pid=" + pid);
            A = (IUIAutomation)new CUIAutomation();
            // ElementFromHandle rather than a ProcessId CONDITION: the interop
            // wrapper refuses CreatePropertyCondition(30005, <int>) with
            // "Value does not fall within the expected range" (measured).
            IntPtr hwnd = IntPtr.Zero;
            for (int i = 0; i < 20 && hwnd == IntPtr.Zero; i++)
            {
                try { hwnd = Process.GetProcessById(pid).MainWindowHandle; } catch { }
                if (hwnd == IntPtr.Zero) System.Threading.Thread.Sleep(400);
            }
            if (hwnd == IntPtr.Zero) { Say("uia3: no main window handle for pid " + pid); goto done; }
            var win = A.ElementFromHandle(hwnd);
            if (win == null) { Say("uia3: ElementFromHandle gave nothing"); goto done; }
            Say("uia3: window name=\"" + win.CurrentName + "\" class=" + win.CurrentClassName);

            IUIAutomationElement edit = null;
            var all = win.FindAll(TreeScope.TreeScope_Descendants, A.CreateTrueCondition());
            Say("uia3: descendants=" + (all == null ? 0 : all.Length));
            for (int i = 0; all != null && i < all.Length; i++)
            {
                var e = all.GetElement(i);
                Say("    type=" + e.CurrentControlType + " id=\"" + e.CurrentAutomationId
                    + "\" name=\"" + e.CurrentName + "\" class=" + e.CurrentClassName);
                if (e.CurrentAutomationId == "richProbe") edit = e;
            }
            if (edit == null) { Say("uia3: no richProbe element"); goto done; }
            Say("uia3: edit controlType=" + edit.CurrentControlType
                + " class=" + edit.CurrentClassName
                + " localized=\"" + edit.CurrentLocalizedControlType + "\"");

            var tp = edit.GetCurrentPattern(TextPatternId) as IUIAutomationTextPattern;
            if (tp == null) { Say("uia3: no TextPattern"); goto done; }
            var doc = tp.DocumentRange;
            Say("uia3: DocumentRange=[" + Esc(doc.GetText(-1)) + "]");

            string[] words = { "plain run", "bold run", "italic run", "under run",
                               "strike run", "mono run", "link run", "heading run" };
            foreach (var w in words)
            {
                var r = doc.FindText(w, 0, 1);
                if (r == null) { Say("  " + w + ": FindText found nothing"); continue; }
                var sb = new StringBuilder("  " + w + " [" + Esc(r.GetText(-1)) + "]");
                for (int k = 0; k < Ids.Length; k++)
                {
                    object v;
                    try { v = r.GetAttributeValue(Ids[k]); }
                    catch (Exception ex) { v = "<threw " + ex.GetType().Name + ">"; }
                    sb.Append(' ').Append(Names[k]).Append('=').Append(Val(v));
                }
                Say(sb.ToString());
                try
                {
                    var kids = r.GetChildren();
                    int n = kids == null ? 0 : kids.Length;
                    if (n == 0) Say("      children: none");
                    for (int i = 0; i < n; i++)
                    {
                        var k = kids.GetElement(i);
                        Say("      child: controlType=" + k.CurrentControlType
                            + " localized=\"" + k.CurrentLocalizedControlType + "\""
                            + " name=\"" + k.CurrentName + "\"");
                    }
                }
                catch (Exception ex) { Say("      GetChildren THREW " + ex.GetType().Name); }
            }

            var whole = new StringBuilder("  WHOLE DOCUMENT");
            for (int k = 0; k < Ids.Length; k++)
            {
                object v;
                try { v = doc.GetAttributeValue(Ids[k]); }
                catch (Exception ex) { v = "<threw " + ex.GetType().Name + ">"; }
                whole.Append(' ').Append(Names[k]).Append('=').Append(Val(v));
            }
            Say(whole.ToString());
        }
        catch (Exception ex)
        {
            Say("uia3 THREW " + ex);
        }
    done:
        Say("uia3 done");
    }
}
