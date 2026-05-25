{******************************************************************************}
{                                                                              }
{  AdidDebugServer — drop-in RTTI debug component                             }
{  Starts an embedded HTTP server on a configurable port, exposes all form     }
{  controls via RTTI enumeration.  Use from a browser or `curl` at runtime.   }
{                                                                              }
{  Endpoints:                                                                  }
{    GET /                 - human-readable index                              }
{    GET /controls         - JSON list of all controls (Name, Class, Bounds)   }
{    GET /controls?grid=8  - text grid (8px resolution) with control overlay   }
{    GET /controls/<name>  - full RTTI property dump for one control           }
{    GET /form             - form info (ClientWidth, ClientHeight, Caption)    }
{                                                                              }
{  Usage: drop TAdidDebugServer on your form, set Port (default 8085), run.   }
{  Or create in code: TAdidDebugServer.Create(Self);                           }
{                                                                              }
{  No external dependencies.  Uses Winsock2 + System.Rtti + System.JSON.      }
{                                                                              }
{  futures/adid_debug_server/AdidDebugServer.pas                              }
{                                                                              }
{******************************************************************************}

unit AdidDebugServer;

{$IF CompilerVersion >= 37}
  {$DEFINE HAS_NEW_RTTI}
{$IFEND}

interface

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows, Winapi.Winsock2,
  {$ENDIF}
  System.Classes, System.SysUtils, System.TypInfo, System.JSON,
  System.Generics.Collections, System.Math,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls;

type
  { Drop-in debug server component.  Constructor auto-starts the HTTP server. }
  TAdidDebugServer = class(TComponent)
  private
    FPort: Word;
    FActive: Boolean;
    FServerThread: TThread;
    FGridCellSize: Integer;
    FLocalHost: string;
    procedure SetActive(const Value: Boolean);
    procedure StartServer;
    procedure StopServer;
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Enumerate all owned controls as JSON string }
    function EnumerateControlsJSON: string;

    { Full RTTI dump for a named control }
    function GetControlDetail(const AName: string): string;

    { Text grid showing control layout at GridCellSize pixels per char }
    function ControlsToGrid: string;

    { Form-level summary }
    function FormInfoJSON: string;
  published
    property Port: Word read FPort write FPort default 8085;
    property Active: Boolean read FActive write SetActive default True;
    property GridCellSize: Integer read FGridCellSize write FGridCellSize default 8;
    property LocalHost: string read FLocalHost write FLocalHost;
  end;

procedure Register;

implementation

uses
  {$IFDEF MSWINDOWS}
  System.SyncObjs,
  {$ENDIF}
  System.Rtti, System.StrUtils;

const
  CRLF = #13#10;
  DEF_PORT = 8085;
  HTTP_200 = 'HTTP/1.0 200 OK' + CRLF;
  HTTP_404 = 'HTTP/1.0 404 Not Found' + CRLF;
  HTTP_CT_JSON    = 'Content-Type: application/json' + CRLF;
  HTTP_CT_TEXT    = 'Content-Type: text/plain; charset=utf-8' + CRLF;
  HTTP_CT_HTML    = 'Content-Type: text/html; charset=utf-8' + CRLF;
  HTTP_CONN_CLOSE = 'Connection: close' + CRLF;

{ ---------------------------------------------------------------------------- }
{  Winsock helper — minimal HTTP 1.0 server in a background thread            }
{ ---------------------------------------------------------------------------- }

{$IFDEF MSWINDOWS}
type
  THttpServerThread = class(TThread)
  private
    FOwner: TAdidDebugServer;
    FPort: Word;
    FLocalHost: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAdidDebugServer; APort: Word; const AHost: string);
  end;

constructor THttpServerThread.Create(AOwner: TAdidDebugServer; APort: Word; const AHost: string);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FOwner := AOwner;
  FPort := APort;
  FLocalHost := AHost;
end;

procedure THttpServerThread.Execute;

  function ReadRequest(Sock: TSocket; out Method, Path, Query: string): Boolean;
  var
    Buf: array[0..4095] of AnsiChar;
    Len: Integer;
    Line, RequestLine: string;
    I, QPos: Integer;
  begin
    Result := False;
    Method := ''; Path := ''; Query := '';
    Len := recv(Sock, Buf, SizeOf(Buf) - 1, 0);
    if Len <= 0 then Exit;
    Buf[Len] := #0;
    // Parse first line: GET /path?query HTTP/1.x
    Line := string(AnsiString(PAnsiChar(@Buf)));
    I := Pos(CRLF, Line);
    if I > 0 then RequestLine := Copy(Line, 1, I - 1)
             else RequestLine := Line;
    // Split method
    I := Pos(' ', RequestLine);
    if I = 0 then Exit;
    Method := UpperCase(Copy(RequestLine, 1, I - 1));
    Delete(RequestLine, 1, I);
    // Split path
    I := Pos(' ', RequestLine);
    if I > 0 then RequestLine := Copy(RequestLine, 1, I - 1);
    // Split query
    QPos := Pos('?', RequestLine);
    if QPos > 0 then
    begin
      Path := Copy(RequestLine, 1, QPos - 1);
      Query := Copy(RequestLine, QPos + 1, MaxInt);
    end
    else
      Path := RequestLine;
    Result := True;
  end;

  procedure SendResponse(Sock: TSocket; const Status, ContentType, Body: string);
  var
    S: UTF8String;
  begin
    S := UTF8String(Status + ContentType + HTTP_CONN_CLOSE + CRLF);
    send(Sock, PByte(S)^, Length(S), 0);
    if Body <> '' then
    begin
      S := UTF8String(Body);
      send(Sock, PByte(S)^, Length(S), 0);
    end;
  end;

  procedure Send404(Sock: TSocket);
  var
    S: UTF8String;
  begin
    S := UTF8String(HTTP_404 + HTTP_CT_TEXT + HTTP_CONN_CLOSE + CRLF + '404 Not Found');
    send(Sock, PByte(S)^, Length(S), 0);
  end;

  procedure HandleRequest(Sock: TSocket);
  var
    Method, Path, Query, Body: string;
  begin
    if not ReadRequest(Sock, Method, Path, Query) then
    begin
      Send404(Sock);
      Exit;
    end;

    Body := '';
    if (Method = 'GET') or (Method = 'HEAD') then
    begin
      if Path = '/' then
      begin
        Body := '<html><body><h1>AdidDebugServer</h1>' +
                '<p>Port: ' + IntToStr(FPort) + '</p>' +
                '<p><a href="/controls">/controls</a> — JSON list</p>' +
                '<p><a href="/controls?grid=8">/controls?grid=8</a> — text grid</p>' +
                '<p><a href="/form">/form</a> — form info</p>' +
                '</body></html>';
        SendResponse(Sock, HTTP_200, HTTP_CT_HTML, Body);
      end
      else if Path = '/controls' then
      begin
        if (Query <> '') and (Pos('grid=', Query) > 0) then
        begin
          Body := FOwner.ControlsToGrid;
          SendResponse(Sock, HTTP_200, HTTP_CT_TEXT, Body);
        end
        else
        begin
          Body := FOwner.EnumerateControlsJSON;
          SendResponse(Sock, HTTP_200, HTTP_CT_JSON, Body);
        end;
      end
      else if Path = '/form' then
      begin
        Body := FOwner.FormInfoJSON;
        SendResponse(Sock, HTTP_200, HTTP_CT_JSON, Body);
      end
      else if Pos('/controls/', Path) = 1 then
      begin
        Body := FOwner.GetControlDetail(Copy(Path, 11, MaxInt));
        if Body <> '' then
          SendResponse(Sock, HTTP_200, HTTP_CT_JSON, Body)
        else
          Send404(Sock);
      end
      else
        Send404(Sock);
    end
    else
      Send404(Sock);
  end;

var
  ListenSock, ClientSock: TSocket;
  Addr: TSockAddrIn;
  WSA: TWSAData;
  TimeOut: Integer;
begin
  if WSAStartup($0202, WSA) <> 0 then
  begin
    OutputDebugString('AdidDebugServer: WSAStartup failed');
    Exit;
  end;
  try
    ListenSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if ListenSock = INVALID_SOCKET then
    begin
      OutputDebugString('AdidDebugServer: socket() failed');
      Exit;
    end;
    try
      FillChar(Addr, SizeOf(Addr), 0);
      Addr.sin_family := AF_INET;
      if FLocalHost <> '' then
        Addr.sin_addr.S_addr := inet_addr(PAnsiChar(UTF8String(FLocalHost)))
      else
        Addr.sin_addr.S_addr := INADDR_ANY;
      Addr.sin_port := htons(FPort);

      if bind(ListenSock, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR then
      begin
        OutputDebugString(PChar(Format('AdidDebugServer: bind() failed, port=%d, err=%d',
          [FPort, WSAGetLastError])));
        Exit;
      end;
      if listen(ListenSock, 4) = SOCKET_ERROR then
      begin
        OutputDebugString('AdidDebugServer: listen() failed');
        Exit;
      end;
      OutputDebugString(PChar(Format('AdidDebugServer: listening on port %d', [FPort])));

      TimeOut := 1000;
      setsockopt(ListenSock, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@TimeOut), SizeOf(TimeOut));

      while not Terminated do
      begin
        ClientSock := accept(ListenSock, nil, nil);
        if ClientSock = INVALID_SOCKET then
        begin
          if WSAGetLastError = WSAETIMEDOUT then Continue;
          Break;
        end;
        try
          HandleRequest(ClientSock);
        finally
          closesocket(ClientSock);
        end;
      end;
    finally
      closesocket(ListenSock);
    end;
  finally
    WSACleanup;
  end;
end;
{$ENDIF MSWINDOWS}

{ ---------------------------------------------------------------------------- }
{  TAdidDebugServer                                                            }
{ ---------------------------------------------------------------------------- }

constructor TAdidDebugServer.Create(AOwner: TComponent);
begin
  inherited;
  FPort := DEF_PORT;
  FGridCellSize := 8;
  FLocalHost := '127.0.0.1';  { bind localhost only — never expose to network }
  if not (csDesigning in ComponentState) then
    StartServer;
end;

destructor TAdidDebugServer.Destroy;
begin
  if FActive then
    StopServer;
  inherited;
end;

procedure TAdidDebugServer.Loaded;
begin
  inherited;
  if FActive and not (csDesigning in ComponentState) then
    StartServer;
end;

procedure TAdidDebugServer.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    if Value then
      StartServer
    else
      StopServer;
  end;
end;

procedure TAdidDebugServer.StartServer;
begin
  {$IFDEF MSWINDOWS}
  if csDesigning in ComponentState then Exit;
  if FActive then Exit; { Already running }
  FServerThread := THttpServerThread.Create(Self, FPort, FLocalHost);
  FActive := True;
  {$ENDIF}
end;

procedure TAdidDebugServer.StopServer;
begin
  {$IFDEF MSWINDOWS}
  if Assigned(FServerThread) then
  begin
    FServerThread.Terminate;
    FServerThread := nil;
  end;
  FActive := False;
  {$ENDIF}
end;

{ ---------------------------------------------------------------------------- }
{  RTTI helpers                                                                }
{ ---------------------------------------------------------------------------- }

function GetControlBounds(AControl: TControl): string;
begin
  Result := Format('{"Left":%d,"Top":%d,"Width":%d,"Height":%d}',
    [AControl.Left, AControl.Top, AControl.Width, AControl.Height]);
end;

function EscapeJSON(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
end;

function GetParentName(AControl: TControl): string;
begin
  if Assigned(AControl.Parent) then
    Result := AControl.Parent.Name
  else
    Result := '';
end;

function GetControlText(AControl: TControl): string;
var
  Ctx: TRttiContext;
  Tp: TRttiType;
  Prop: TRttiProperty;
begin
  Result := '';
  Ctx := TRttiContext.Create;
  try
    Tp := Ctx.GetType(AControl.ClassType);
    { Try 'Caption' first (TLabel, TButton, TCheckBox, etc.) }
    Prop := Tp.GetProperty('Caption');
    if Assigned(Prop) and Prop.IsReadable then
      Result := EscapeJSON(Prop.GetValue(AControl).ToString)
    else
    begin
      { Fall back to 'Text' (TEdit, TMemo, etc.) }
      Prop := Tp.GetProperty('Text');
      if Assigned(Prop) and Prop.IsReadable then
        Result := EscapeJSON(Prop.GetValue(AControl).ToString);
    end;
  finally
    Ctx.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{  Control enumeration                                                         }
{ ---------------------------------------------------------------------------- }

procedure EnumerateAll(AForm: TWinControl; const List: TList<TControl>);
var
  I: Integer;
  Ctrl: TControl;
begin
  for I := 0 to AForm.ControlCount - 1 do
  begin
    Ctrl := AForm.Controls[I];
    List.Add(Ctrl);
    if Ctrl is TWinControl then
      EnumerateAll(TWinControl(Ctrl), List);
  end;
end;

function TAdidDebugServer.EnumerateControlsJSON: string;
var
  List: TList<TControl>;
  Ctrl: TControl;
  Items: TStringList;
  Root: TComponent;
  I: Integer;
begin
  List := TList<TControl>.Create;
  Items := TStringList.Create;
  try
    // Walk Owner -> all components, then recursively walk child controls
    if Owner is TForm then
    begin
      Root := Owner;
      for I := 0 to Root.ComponentCount - 1 do
        if Root.Components[I] is TControl then
          List.Add(TControl(Root.Components[I]));

      { Also walk visual child tree for parented controls not owned by the form }
      EnumerateAll(TForm(Owner), List);
    end;

    Items.Add('[');
    for I := 0 to List.Count - 1 do
    begin
      Ctrl := List[I];
      if I > 0 then Items[Items.Count - 1] := Items[Items.Count - 1] + ',';

      Items.Add(Format(
        '{"Name":"%s","Class":"%s","Bounds":%s,"Text":"%s","Visible":%s,"Enabled":%s,"Parent":"%s"}',
        [EscapeJSON(Ctrl.Name),
         Ctrl.ClassName,
         GetControlBounds(Ctrl),
         GetControlText(Ctrl),
         BoolToStr(Ctrl.Visible, True),
         BoolToStr(Ctrl.Enabled, True),
          EscapeJSON(GetParentName(Ctrl))]));
    end;
    Items.Add(']');
    Result := Items.Text;
  finally
    List.Free;
    Items.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{  Single control RTTI detail                                                  }
{ ---------------------------------------------------------------------------- }

function TAdidDebugServer.GetControlDetail(const AName: string): string;
var
  Root: TComponent;
  Ctrl: TComponent;
  I, J: Integer;
  Ctx: TRttiContext;
  RttiType: TRttiType;
  RttiProp: TRttiProperty;
  Items: TStringList;
  Val: TValue;
  ValStr: string;
begin
  Result := '';
  Ctrl := nil;
  if Owner is TForm then
  begin
    Root := Owner;
    for I := 0 to Root.ComponentCount - 1 do
      if SameText(Root.Components[I].Name, AName) then
      begin
        Ctrl := Root.Components[I];
        Break;
      end;
  end;
  if Ctrl = nil then
    Exit;

  Items := TStringList.Create;
  try
    Items.Add('{');
    Items.Add(Format('  "Name":"%s",', [EscapeJSON(Ctrl.Name)]));
    Items.Add(Format('  "Class":"%s",', [Ctrl.ClassName]));
    if Ctrl is TControl then
    begin
      Items.Add(Format('  "Left":%d,', [TControl(Ctrl).Left]));
      Items.Add(Format('  "Top":%d,', [TControl(Ctrl).Top]));
      Items.Add(Format('  "Width":%d,', [TControl(Ctrl).Width]));
      Items.Add(Format('  "Height":%d,', [TControl(Ctrl).Height]));
      Items.Add(Format('  "Visible":%s,', [BoolToStr(TControl(Ctrl).Visible, True)]));
      Items.Add(Format('  "Enabled":%s,', [BoolToStr(TControl(Ctrl).Enabled, True)]));
      Items.Add(Format('  "Parent":"%s",', [EscapeJSON(GetParentName(TControl(Ctrl)))]));
      if Ctrl is TWinControl then
        Items.Add(Format('  "ChildCount":%d,', [TWinControl(Ctrl).ControlCount]));
    end;
    Items.Add('  "Properties":{');

    // RTTI property dump (published + public readable)
    Ctx := TRttiContext.Create;
    try
      RttiType := Ctx.GetType(Ctrl.ClassType);
      J := 0;
      for RttiProp in RttiType.GetProperties do
      begin
        if not RttiProp.IsReadable then Continue;
        if SameText(RttiProp.Name, 'Name') then Continue; // already shown
        try
          Val := RttiProp.GetValue(Ctrl);
          if Val.IsEmpty then Continue;
          ValStr := Val.ToString;
          if Length(ValStr) > 200 then
            ValStr := Copy(ValStr, 1, 200) + '...[truncated]';
          if J > 0 then
            Items[Items.Count - 1] := Items[Items.Count - 1] + ',';
          Items.Add(Format('    "%s":"%s"', [EscapeJSON(RttiProp.Name), EscapeJSON(ValStr)]));
          Inc(J);
          if J > 60 then // limit output
          begin
            Items.Add('    "...":"(truncated)"');
            Break;
          end;
        except
        end;
      end;
    finally
      Ctx.Free;
    end;
    Items.Add('  }');
    Items.Add('}');
    Result := Items.Text;
  finally
    Items.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{  Text grid (8px resolution) — compact visual layout map                     }
{ ---------------------------------------------------------------------------- }

function TAdidDebugServer.ControlsToGrid: string;
var
  Form: TForm;
  List: TList<TControl>;
  GridCols, GridRows: Integer;
  Grid: array of array of AnsiChar;
  Ctrl: TControl;
  X, Y, C, R, I: Integer;
  Ch: AnsiChar;
  Bounds: TRect;
  Lines: TStringList;
begin
  Result := '';
  if not (Owner is TForm) then Exit;
  Form := TForm(Owner);

  GridCols := (Form.ClientWidth div FGridCellSize) + 1;
  GridRows := (Form.ClientHeight div FGridCellSize) + 1;
  if (GridCols <= 0) or (GridRows <= 0) then Exit;

  // Allocate and fill grid
  SetLength(Grid, GridRows, GridCols);
  for R := 0 to GridRows - 1 do
    for C := 0 to GridCols - 1 do
      Grid[R, C] := '.';

  // Collect controls
  List := TList<TControl>.Create;
  try
    EnumerateAll(Form, List);

    // Mark grid cells occupied by controls (using class name first char)
    for I := 0 to List.Count - 1 do
    begin
      Ctrl := List[I];
      if (Ctrl = Form) or not Ctrl.Visible then Continue;

      Bounds := Ctrl.BoundsRect;
      if (Ctrl is TWinControl) and (TWinControl(Ctrl).Parent <> Form) then
        Bounds.TopLeft := Form.ScreenToClient(Ctrl.Parent.ClientToScreen(Bounds.TopLeft));

      // Pick character: 2nd character of class name (skip 'T' prefix);
      // if class name has only 1 char, use '?'
      if Length(Ctrl.ClassName) >= 2 then
        Ch := AnsiChar(Ctrl.ClassName[2])
      else
        Ch := '?';

      // Fill cells
      for R := Max(0, Bounds.Top div FGridCellSize) to
               Min(GridRows - 1, (Bounds.Bottom - 1) div FGridCellSize) do
        for C := Max(0, Bounds.Left div FGridCellSize) to
                 Min(GridCols - 1, (Bounds.Right - 1) div FGridCellSize) do
          Grid[R, C] := Ch;
    end;

    // Build text output
    Lines := TStringList.Create;
    try
      Lines.Add(Format('Form: %s  Client=%dx%d  Grid: %dpx/cell  Legend below',
        [EscapeJSON(Form.Caption), Form.ClientWidth, Form.ClientHeight, FGridCellSize]));
      Lines.Add(StringOfChar('-', GridCols + 10));

      // Column header every 10 cells
      Lines.Add(Format('     %s', [StringOfChar('0', GridCols)]));

      for R := 0 to GridRows - 1 do
        Lines.Add(Format('%4d %s', [R * FGridCellSize, string(PAnsiChar(@Grid[R, 0]))]));

      // Legend
      Lines.Add(StringOfChar('-', GridCols + 10));
      Lines.Add('Legend:');
      for I := 0 to List.Count - 1 do
      begin
        Ctrl := List[I];
        if Ctrl = Form then Continue;
        if Length(Ctrl.ClassName) >= 2 then
          Lines.Add(Format('  %s  %s %s  @ (%d,%d)  %s',
            [AnsiChar(Ctrl.ClassName[2]),
             Ctrl.ClassName,
             Ctrl.Name,
             Ctrl.Left, Ctrl.Top,
             GetControlText(Ctrl)]))
        else
          Lines.Add(Format('  ?  %s %s  @ (%d,%d)  %s',
            [Ctrl.ClassName,
             Ctrl.Name,
             Ctrl.Left, Ctrl.Top,
             GetControlText(Ctrl)]));
      end;
      Result := Lines.Text;
    finally
      Lines.Free;
    end;
  finally
    List.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{  Form-level info                                                             }
{ ---------------------------------------------------------------------------- }

function TAdidDebugServer.FormInfoJSON: string;
var
  F: TForm;
begin
  if not (Owner is TForm) then
    Exit('{"error":"Owner is not a TForm"}');
  F := TForm(Owner);
  Result := Format(
    '{"Caption":"%s","ClientWidth":%d,"ClientHeight":%d,' +
    '"ComponentCount":%d,"ControlCount":%d,"WindowState":"%s"}',
    [EscapeJSON(F.Caption), F.ClientWidth, F.ClientHeight,
     F.ComponentCount, F.ControlCount,
     GetEnumName(TypeInfo(TWindowState), Ord(F.WindowState))]);
end;

{ ---------------------------------------------------------------------------- }
{  Register for IDE component palette                                         }
{ ---------------------------------------------------------------------------- }

procedure Register;
begin
  RegisterComponents('ADID Debug', [TAdidDebugServer]);
end;

end.
