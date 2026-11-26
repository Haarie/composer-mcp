using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
// Win32 helpers for the Technical Illustration export (Composer's COM API has no vector export).
public static class CrUi {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, int m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, UIntPtr s, uint t, uint pr);
  [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, UIntPtr s, uint t);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr a, byte[] b, UIntPtr s, out UIntPtr r);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  public static string Text(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  public static string Class(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static List<IntPtr> Children(IntPtr p) { var r = new List<IntPtr>(); EnumChildWindows(p, (h, l) => { r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static IntPtr FindChild(IntPtr p, string cls, string text, int id) {
    foreach (var h in Children(p)) {
      if (cls != null && Class(h) != cls) continue;
      if (text != null && Text(h).Trim() != text) continue;
      if (id != 0 && GetDlgCtrlID(h) != id) continue;
      return h;
    }
    return IntPtr.Zero;
  }
  public static List<IntPtr> ProcessDialogs(uint pid) {
    var r = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && Class(h) == "#32770" && IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero);
    return r;
  }
  public static uint ProcessOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

  // Toolbar buttons (index, command id, text, client rect) read from the other process' memory.
  public static List<string> ToolbarButtons(IntPtr tb) {
    var res = new List<string>();
    uint pid = ProcessOf(tb);
    IntPtr hp = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid); // VM_OPERATION|VM_READ|VM_WRITE|QUERY_INFORMATION
    if (hp == IntPtr.Zero) throw new Exception("OpenProcess failed");
    IntPtr mem = VirtualAllocEx(hp, IntPtr.Zero, (UIntPtr)1024, 0x3000, 0x04);
    try {
      int n = (int)SendMessage(tb, 0x0418, IntPtr.Zero, IntPtr.Zero); // TB_BUTTONCOUNT
      for (int i = 0; i < n; i++) {
        byte[] b = new byte[32]; UIntPtr rd;
        SendMessage(tb, 0x0417, (IntPtr)i, mem); // TB_GETBUTTON
        ReadProcessMemory(hp, mem, b, (UIntPtr)32, out rd);
        int cmd = BitConverter.ToInt32(b, 4); byte style = b[9];
        byte[] t = new byte[512];
        int len = (int)SendMessage(tb, 0x044B, (IntPtr)cmd, mem); // TB_GETBUTTONTEXTW
        string txt = "";
        if (len > 0) { ReadProcessMemory(hp, mem, t, (UIntPtr)Math.Min(510, (len + 1) * 2), out rd); txt = Encoding.Unicode.GetString(t, 0, len * 2); }
        byte[] rb = new byte[16];
        SendMessage(tb, 0x041D, (IntPtr)i, mem); // TB_GETITEMRECT
        ReadProcessMemory(hp, mem, rb, (UIntPtr)16, out rd);
        res.Add(i + "|" + cmd + "|" + style + "|" + txt + "|" + BitConverter.ToInt32(rb, 0) + "," + BitConverter.ToInt32(rb, 4) + "," + BitConverter.ToInt32(rb, 8) + "," + BitConverter.ToInt32(rb, 12));
      }
    } finally { VirtualFreeEx(hp, mem, UIntPtr.Zero, 0x8000); CloseHandle(hp); }
    return res;
  }
  public static void Click(IntPtr h, int x, int y) {
    IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
    PostMessage(h, 0x0201, (IntPtr)1, lp); PostMessage(h, 0x0202, IntPtr.Zero, lp);
  }
}
