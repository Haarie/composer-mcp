using System; using System.Reflection; using System.Runtime.InteropServices;
// Builds an in-memory interop assembly from Composer's type library.
// Composer's own IDispatch does not resolve IApplication/IDocument members (DISP_E_UNKNOWNNAME),
// but the interfaces are dual, so calls through the generated interfaces go via the vtable and work.
public class ComposerImporter : ITypeLibImporterNotifySink {
  [DllImport("oleaut32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
  [return: MarshalAs(UnmanagedType.Interface)] static extern object LoadTypeLib(string file);
  public void ReportEvent(ImporterEventKind k, int c, string m) { }
  public Assembly ResolveRef(object tl) {
    return Assembly.Load("stdole, Version=7.0.3300.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a");
  }
  public static Assembly Import(string file) {
    object tl = LoadTypeLib(file);
    // PreventClassMembers: the coclasses (with their event sources) fail type verification otherwise
    return new TypeLibConverter().ConvertTypeLibToAssembly(tl, "ComposerInterop.dll",
      TypeLibImporterFlags.PreventClassMembers, new ComposerImporter(), null, null, "ComposerInterop", new Version(1, 0));
  }
}
