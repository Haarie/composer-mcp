# SOLIDWORKS Composer MCP

An [MCP](https://modelcontextprotocol.io) server that lets an AI assistant (Claude Desktop or any other MCP client) drive **SOLIDWORKS Composer** on a Windows PC through Composer's COM API: open files, inspect the full API, and run PowerShell scripts against the open document.

No npm dependencies: a small Node.js server speaks MCP over stdio and forwards each call to one persistent PowerShell process that holds the COM connection.

## Tools

| Tool | What it does |
|---|---|
| `status` | Check the connection; with `start: true` starts a Composer window connected to the MCP. Returns version, open documents and the active one. |
| `open` | Open a file (`.smg`, `.smgXml`, `.smgProj`, `.stp`/`.step` and other formats Composer imports). Starts Composer if needed. |
| `api_reference` | The complete Composer COM API, read from its type library: `IApplication` and `IDocument` members with parameter types, and all enums. |
| `run_script` | Run PowerShell in the persistent session, with `$app` (application) and `$doc` (active document) predefined. |
| `diagnose` | COM registration, running Composer processes and connection state. |

Example `run_script` code:

```powershell
$doc.RenderMode = 3              # Flat Technical
$app.RunRibbonCommand(32)        # Align camera 3/4 X- Y- Z+
$doc.SetPropertySet('<CLitSelection Name="" Ident="-1">ARoot.APart#</CLitSelection>',
  '<CLitPropertySet><Actor.Name Value="New name"></Actor.Name></CLitPropertySet>')
$doc.Save()
```

Enums are plain integers; methods that return a document return a wrapped object, so `$app.Open($path).FileName` works.

## Why this exists: Composer's broken IDispatch

Composer registers as `DSComposer.Application`, but its `IDispatch` does not resolve any member: late-bound calls such as `$app.Open(...)` from PowerShell, VBScript or Python `win32com` fail with `DISP_E_UNKNOWNNAME`, and calls by DISPID fail with `DISP_E_MEMBERNOTFOUND`.

`IApplication` and `IDocument` are, however, **dual** interfaces, and `QueryInterface` for them succeeds. On first use this MCP builds an interop assembly in memory from the type library inside `composer.exe` (`TypeLibConverter`, see `server/ps/interop.cs`) and calls every member through the vtable. `server/ps/host.ps1` wraps the COM objects in PowerShell objects so scripts keep the familiar `$app.Method()` / `$doc.Property = x` syntax.

## Requirements

- Windows with SOLIDWORKS Composer installed (tested with Composer 2026, version 7.13.5)
- Composer registered for COM: run `composer.exe /regserver` once as administrator if `diagnose` reports it missing
- Windows PowerShell 5.1 (included in Windows) and Node.js 16+ (Claude Desktop ships its own)

## Installation

**Claude Desktop:** download the `.mcpb` file from the [Releases](../../releases) page and open it, or install it under Settings → Extensions.

**Build the `.mcpb` yourself:** zip `manifest.json` and the `server` folder (with the zip root at this folder) and rename the zip to `composer-mcp.mcpb`.

**Other MCP clients:**

```json
{
  "mcpServers": {
    "composer": { "command": "node", "args": ["C:\\path\\to\\composer-mcp\\server\\index.js"] }
  }
}
```

## Notes

- Composer does not register in the Running Object Table, so a Composer you started by hand cannot be reached. Use `status` with `start: true`, then `open`.
- All COM clients share one Composer process. Two MCP sessions (or this MCP and another tool) connected at the same time control the same window and the same active document.
- Calls run one at a time; a call times out after 15 minutes, which restarts the PowerShell host.

## License

[MIT](LICENSE)
