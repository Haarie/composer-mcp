using System;
using System.Text;
using System.Runtime.InteropServices;
using TYPEDESC = System.Runtime.InteropServices.ComTypes.TYPEDESC;
using ITypeLib = System.Runtime.InteropServices.ComTypes.ITypeLib;
using ITypeInfo = System.Runtime.InteropServices.ComTypes.ITypeInfo;
using TYPEATTR = System.Runtime.InteropServices.ComTypes.TYPEATTR;
using VARDESC = System.Runtime.InteropServices.ComTypes.VARDESC;
using FUNCDESC = System.Runtime.InteropServices.ComTypes.FUNCDESC;
using ELEMDESC = System.Runtime.InteropServices.ComTypes.ELEMDESC;
using INVOKEKIND = System.Runtime.InteropServices.ComTypes.INVOKEKIND;
using VARKIND = System.Runtime.InteropServices.ComTypes.VARKIND;
public static class ComposerTlbDump {
  [DllImport("oleaut32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
  static extern ITypeLib LoadTypeLib(string file);
  static string TypeName(ITypeInfo ti, TYPEDESC td) {
    VarEnum vt = (VarEnum)td.vt;
    try {
      if (vt == VarEnum.VT_PTR) { TYPEDESC inner = (TYPEDESC)Marshal.PtrToStructure(td.lpValue, typeof(TYPEDESC)); return TypeName(ti, inner) + "*"; }
      if (vt == VarEnum.VT_USERDEFINED) { ITypeInfo r; ti.GetRefTypeInfo(unchecked((int)td.lpValue.ToInt64()), out r); string n, d, h; int c; r.GetDocumentation(-1, out n, out d, out c, out h); return n; }
    } catch { return vt.ToString().Replace("VT_", "") + "?"; }
    if (vt == VarEnum.VT_SAFEARRAY) { return "SAFEARRAY"; }
    return vt.ToString().Replace("VT_", "");
  }
  public static string Dump(string file) {
    ITypeLib tl = LoadTypeLib(file);
    StringBuilder sb = new StringBuilder();
    int n = tl.GetTypeInfoCount();
    for (int i = 0; i < n; i++) {
      ITypeInfo ti; tl.GetTypeInfo(i, out ti);
      string name, doc, hf; int hc; ti.GetDocumentation(-1, out name, out doc, out hc, out hf);
      IntPtr pta; ti.GetTypeAttr(out pta); TYPEATTR ta = (TYPEATTR)Marshal.PtrToStructure(pta, typeof(TYPEATTR));
      sb.AppendLine("## " + name + " [" + ta.typekind.ToString().Replace("TKIND_", "") + "]");
      for (int v = 0; v < ta.cVars; v++) {
        IntPtr pv; ti.GetVarDesc(v, out pv); VARDESC vd = (VARDESC)Marshal.PtrToStructure(pv, typeof(VARDESC));
        string[] nm = new string[1]; int cn; ti.GetNames(vd.memid, nm, 1, out cn);
        string val = "";
        if (vd.varkind == VARKIND.VAR_CONST) { try { val = " = " + Marshal.GetObjectForNativeVariant(vd.desc.lpvarValue); } catch {} }
        sb.AppendLine("  " + nm[0] + val);
        ti.ReleaseVarDesc(pv);
      }
      for (int f = 0; f < ta.cFuncs; f++) {
        IntPtr pf; ti.GetFuncDesc(f, out pf); FUNCDESC fd = (FUNCDESC)Marshal.PtrToStructure(pf, typeof(FUNCDESC));
        string[] names = new string[fd.cParams + 1]; int cnt; ti.GetNames(fd.memid, names, names.Length, out cnt);
        if (fd.memid < 0x60030000 && fd.memid >= 0x60000000) { ti.ReleaseFuncDesc(pf); continue; } // skip IUnknown/IDispatch
        StringBuilder ps = new StringBuilder();
        int sz = Marshal.SizeOf(typeof(ELEMDESC));
        for (int p = 0; p < fd.cParams; p++) {
          ELEMDESC ed = (ELEMDESC)Marshal.PtrToStructure(new IntPtr(fd.lprgelemdescParam.ToInt64() + p * sz), typeof(ELEMDESC));
          if (p > 0) ps.Append(", ");
          ps.Append(TypeName(ti, ed.tdesc) + " " + (p + 1 < cnt ? names[p + 1] : "value"));
        }
        string kind = fd.invkind == INVOKEKIND.INVOKE_FUNC ? "" : (" {" + fd.invkind.ToString().Replace("INVOKE_", "") + "}");
        sb.AppendLine("  " + TypeName(ti, fd.elemdescFunc.tdesc) + " " + names[0] + "(" + ps + ")" + kind);
        ti.ReleaseFuncDesc(pf);
      }
      ti.ReleaseTypeAttr(pta);
    }
    return sb.ToString();
  }
}
