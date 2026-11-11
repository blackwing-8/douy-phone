using System.ComponentModel;
using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using DOUY.Pc.Media;
using DOUY.Pc.Rtmp;
using DOUY.Pc.Usb;

namespace DOUY.Pc;

/// <summary>
/// 兜鱼手机输出 控制面板（单窗口，全部控件代码创建，无 Designer / .resx）。
///
/// 三种输出模式：
///   * USB 连接    —— OBS 推流到本机 RTMP，再经 usbmuxd 走数据线送进 iPhone；
///   * 局域网 RTMP —— 手机与电脑同一 WiFi，直接拉本机 RTMP 地址；
///   * 外部推流    —— 把收到的流用 ffmpeg 转推到外部 rtmp(s) 服务器。
///
/// 设计约束：
///   * 只用 BCL + WinForms，不加任何 NuGet 包；
///   * 网络 / 进程操作全部在后台线程，UI 只用 BeginInvoke 更新；
///   * 所有异常一律 catch 并写 AppLog，绝不让界面崩掉。
/// </summary>
public sealed class MainForm : Form
{
    private const string AppTitle = "兜鱼手机输出";
    private const string AppSubtitle = "OBS → iPhone USB / 局域网 RTMP · 复刻版 1.0.0";
    private const string DefaultPath = "live/douy";
    private const string FirewallRuleName = "DOUY Phone Output LAN";
    private const string FirewallRuleLegacyName = "DOUY OBS 手机局域网接收";
    private const string DeviceHint = "未发现 iPhone（请解锁并信任此电脑，并安装 Apple Devices 或 iTunes）";
    private const int MaxLogLines = 2000;

    private enum OutputMode
    {
        Usb,
        LanRtmp,
        External,
    }

    // ───────────────────────── 布局 / 运行状态 ─────────────────────────

    private float _scale = 1f;
    private bool _sizeInitialized;
    private bool _inLayout;
    private bool _closing;
    private bool _busy;
    private bool _busyStart = true;
    private bool _running;
    private bool _loadingSettings = true;
    private bool _refreshingDevices;
    private bool _devicesLoaded;
    private bool _uiBuilt;
    private bool _darkTitleBarApplied;
    private int _logLineCount;

    private DateTime _copyFlashUntil = DateTime.MinValue;
    private long _lastSettingsWarnTick;

    private OutputMode _mode = OutputMode.Usb;
    private AppSettings _settings = new();
    private string? _preferredUdid;

    private readonly object _sync = new();
    private MediaHub? _hub;
    private IRtmpServer? _server;
    private UsbBridge? _bridge;
    private Process? _ffmpeg;

    private System.Windows.Forms.Timer _uiTimer = null!;

    // ───────────────────────── 控件 ─────────────────────────

    private PictureBox _logoBox = null!;
    private Label _titleLabel = null!;
    private Label _subtitleLabel = null!;

    private CardPanel _modeCard = null!;
    private Label _modeTitleLabel = null!;
    private Label _modeHintLabel = null!;
    private Button _modeUsbBtn = null!;
    private Button _modeLanBtn = null!;
    private Button _modeExternalBtn = null!;

    private CardPanel _paramCard = null!;
    private Label _paramTitleLabel = null!;
    private Panel _paramRow1 = null!;
    private Panel _usbRow = null!;
    private Panel _extRow1 = null!;
    private Panel _extRow2 = null!;

    private Label _portLabel = null!;
    private NumericUpDown _portBox = null!;
    private Label _pathLabel = null!;
    private TextBox _pathBox = null!;
    private Label _pathHintLabel = null!;

    private Label _deviceLabel = null!;
    private ComboBox _deviceCombo = null!;
    private Button _refreshDevicesBtn = null!;
    private Label _devicePortLabel = null!;
    private NumericUpDown _devicePortBox = null!;

    private Label _externalUrlLabel = null!;
    private TextBox _externalUrlBox = null!;
    private Label _externalHintLabel = null!;
    private Label _ffmpegLabel = null!;
    private TextBox _ffmpegBox = null!;
    private Button _browseFfmpegBtn = null!;

    private CardPanel _addressCard = null!;
    private Label _addressTitleLabel = null!;
    private TextBox _addressBox = null!;
    private Button _copyAddressBtn = null!;

    private Panel _actionPanel = null!;
    private Button _startBtn = null!;
    private Button _firewallBtn = null!;
    private Label _actionHintLabel = null!;

    private CardPanel _statusCard = null!;
    private Label _statusDot = null!;
    private Label _statusText = null!;
    private Label _statsLabel = null!;

    private CardPanel _logCard = null!;
    private Label _logTitleLabel = null!;
    private Button _clearLogBtn = null!;
    private TextBox _logBox = null!;

    // ───────────────────────── 构造 ─────────────────────────

    public MainForm()
    {
        try
        {
            _settings = LoadSettingsFromDisk();
        }
        catch (Exception ex)
        {
            AppLog.Warn("读取设置失败，使用默认值：" + ex.Message);
            _settings = new AppSettings();
        }

        SuspendLayout();

        Text = AppTitle + " · DOUY";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.Sizable;
        BackColor = Theme.Bg;
        ForeColor = Theme.Text;
        Font = UiFont(9f);
        AutoScaleMode = AutoScaleMode.None;
        DoubleBuffered = true;
        MinimumSize = new Size(880, 620);
        ClientSize = new Size(900, 640);
        KeyPreview = true;

        BuildUi();

        _uiTimer = new System.Windows.Forms.Timer { Interval = 500 };
        _uiTimer.Tick += OnUiTick;

        ApplySettingsToUi(_settings);

        FillLogFromSnapshot();
        AppLog.LineWritten += OnLogLine;

        _uiTimer.Start();
        UpdateAddressPreview();
        UpdateActionButton();
        RefreshStatusPanel();
        RefreshStats();

        DpiChanged += OnDpiChangedHandler;

        ResumeLayout(false);
    }

    // ───────────────────────── UI 构建 ─────────────────────────

    /// <summary>左上角品牌 logo（嵌入资源 Assets/logo.png；缺失时自动隐藏，不影响界面）。</summary>
    private static PictureBox MakeLogoBox()
    {
        var box = new PictureBox
        {
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Theme.Bg,
            Visible = false,
        };

        try
        {
            using var stream = typeof(MainForm).Assembly
                .GetManifestResourceStream("DOUY.Pc.Assets.logo.png");
            if (stream != null)
            {
                using var source = Image.FromStream(stream);
                box.Image = new Bitmap(source);
                box.Visible = true;
            }
        }
        catch
        {
            // 资源缺失不致命，界面照常
        }

        return box;
    }

    private void BuildUi()
    {
        _logoBox = MakeLogoBox();
        _titleLabel = MakeLabel(AppTitle, 20f, Theme.Text, bold: true, back: Theme.Bg);
        _subtitleLabel = MakeLabel(AppSubtitle, 9f, Theme.Muted, back: Theme.Bg);

        // ---- 模式卡片 ----
        _modeCard = MakeCard();
        _modeTitleLabel = MakeLabel("输出模式", 9f, Theme.Muted);
        _modeHintLabel = MakeLabel(ModeHint(OutputMode.Usb), 8.5f, Theme.Dim);
        _modeUsbBtn = MakeButton("USB 连接");
        _modeLanBtn = MakeButton("局域网 RTMP");
        _modeExternalBtn = MakeButton("外部推流");
        _modeUsbBtn.Click += (_, _) => SelectMode(OutputMode.Usb, persist: true);
        _modeLanBtn.Click += (_, _) => SelectMode(OutputMode.LanRtmp, persist: true);
        _modeExternalBtn.Click += (_, _) => SelectMode(OutputMode.External, persist: true);
        _modeCard.Controls.Add(_modeTitleLabel);
        _modeCard.Controls.Add(_modeUsbBtn);
        _modeCard.Controls.Add(_modeLanBtn);
        _modeCard.Controls.Add(_modeExternalBtn);
        _modeCard.Controls.Add(_modeHintLabel);
        ApplyModeButtonStyle(_modeUsbBtn, true);
        ApplyModeButtonStyle(_modeLanBtn, false);
        ApplyModeButtonStyle(_modeExternalBtn, false);

        // ---- 参数卡片 ----
        _paramCard = MakeCard();
        _paramTitleLabel = MakeLabel("接收参数", 9f, Theme.Muted);

        _paramRow1 = MakeRow();
        _portLabel = MakeLabel("端口", 9f, Theme.Text);
        _portBox = MakeNumeric(19350m, 1024m, 65535m);
        _pathLabel = MakeLabel("流路径", 9f, Theme.Text);
        _pathBox = MakeTextBox(DefaultPath, readOnly: true);
        _pathBox.TabStop = false; // 只读信息框不参与 Tab，避免抢焦点后被整段选中
        _pathHintLabel = MakeLabel("OBS：服务器 rtmp://127.0.0.1:端口，串流密钥填此路径", 8.5f, Theme.Dim);
        _paramRow1.Controls.Add(_portLabel);
        _paramRow1.Controls.Add(_portBox);
        _paramRow1.Controls.Add(_pathLabel);
        _paramRow1.Controls.Add(_pathBox);
        _paramRow1.Controls.Add(_pathHintLabel);

        _usbRow = MakeRow();
        _deviceLabel = MakeLabel("设备", 9f, Theme.Text);
        _deviceCombo = new DarkComboBox();
        _refreshDevicesBtn = MakeButton("刷新设备");
        _refreshDevicesBtn.Font = UiFont(8.5f);
        _refreshDevicesBtn.Click += (_, _) => RefreshDevices(quiet: false);
        _devicePortLabel = MakeLabel("设备端口", 9f, Theme.Text);
        _devicePortBox = MakeNumeric(28767m, 1m, 65535m);
        _usbRow.Controls.Add(_deviceLabel);
        _usbRow.Controls.Add(_deviceCombo);
        _usbRow.Controls.Add(_refreshDevicesBtn);
        _usbRow.Controls.Add(_devicePortLabel);
        _usbRow.Controls.Add(_devicePortBox);

        _extRow1 = MakeRow();
        _externalUrlLabel = MakeLabel("目标地址", 9f, Theme.Text);
        _externalUrlBox = MakeTextBox(string.Empty, readOnly: false, placeholder: "rtmp://服务器/live/stream");
        _externalHintLabel = MakeLabel("例：rtmp://live.example.com/live/stream（-c copy 转推）", 8.5f, Theme.Dim);
        _extRow1.Controls.Add(_externalUrlLabel);
        _extRow1.Controls.Add(_externalUrlBox);
        _extRow1.Controls.Add(_externalHintLabel);

        _extRow2 = MakeRow();
        _ffmpegLabel = MakeLabel("ffmpeg 路径", 9f, Theme.Text);
        _ffmpegBox = MakeTextBox(string.Empty, readOnly: false, placeholder: "留空自动查找 ffmpeg.exe（程序目录 / 工作目录 / PATH）");
        _browseFfmpegBtn = MakeButton("浏览…");
        _browseFfmpegBtn.Font = UiFont(8.5f);
        _browseFfmpegBtn.Click += (_, _) => BrowseFfmpeg();
        _extRow2.Controls.Add(_ffmpegLabel);
        _extRow2.Controls.Add(_ffmpegBox);
        _extRow2.Controls.Add(_browseFfmpegBtn);

        _paramCard.Controls.Add(_paramTitleLabel);
        _paramCard.Controls.Add(_paramRow1);
        _paramCard.Controls.Add(_usbRow);
        _paramCard.Controls.Add(_extRow1);
        _paramCard.Controls.Add(_extRow2);

        // ---- 地址卡片 ----
        _addressCard = MakeCard();
        _addressTitleLabel = MakeLabel("地址速查：OBS 用上面的服务器+推流码，手机用下面的完整地址", 9f, Theme.Muted);
        _addressBox = MakeTextBox(string.Empty, readOnly: true, multiline: true);
        _addressBox.Font = LogFont(9f);
        _addressBox.ScrollBars = ScrollBars.Vertical;
        _addressBox.TabStop = false;
        _copyAddressBtn = MakeButton("复制地址");
        _copyAddressBtn.Font = UiFont(8.5f);
        _copyAddressBtn.Click += (_, _) => CopyAddress();
        _addressCard.Controls.Add(_addressTitleLabel);
        _addressCard.Controls.Add(_addressBox);
        _addressCard.Controls.Add(_copyAddressBtn);

        // ---- 操作区 ----
        _actionPanel = new Panel { BackColor = Theme.Bg };
        _startBtn = MakeButton("开始输出", primary: true, size: 10f);
        _startBtn.Click += (_, _) => OnStartStopClick();
        _firewallBtn = MakeButton("修复访问权限");
        _firewallBtn.Click += (_, _) => FixFirewall();
        _actionHintLabel = MakeLabel("「修复访问权限」用管理员 netsh 为 TCP 端口添加/更新入站规则", 8.5f, Theme.Dim, back: Theme.Bg);
        _actionPanel.Controls.Add(_startBtn);
        _actionPanel.Controls.Add(_firewallBtn);
        _actionPanel.Controls.Add(_actionHintLabel);

        // ---- 状态卡片 ----
        _statusCard = MakeCard();
        _statusDot = MakeLabel("●", 14f, Theme.Muted, bold: true);
        _statusText = MakeLabel("未开始输出", 11f, Theme.Muted, bold: true);
        _statsLabel = MakeLabel("视频 0 帧 · 音频 0 帧 · 观众 0 · 丢弃 0", 9f, Theme.Muted);
        _statusCard.Controls.Add(_statusDot);
        _statusCard.Controls.Add(_statusText);
        _statusCard.Controls.Add(_statsLabel);

        // ---- 日志卡片 ----
        _logCard = MakeCard();
        _logTitleLabel = MakeLabel("运行日志 · 最近 2000 行", 9f, Theme.Muted);
        _clearLogBtn = MakeButton("清空");
        _clearLogBtn.Font = UiFont(8.5f);
        _clearLogBtn.Click += (_, _) => ClearLog();
        _logBox = new TextBox
        {
            Multiline = true,
            ReadOnly = true,
            WordWrap = false,
            ScrollBars = ScrollBars.Both,
            BackColor = Theme.LogBg,
            ForeColor = ColorTranslator.FromHtml("#D8DBDF"),
            Font = LogFont(9f),
            BorderStyle = BorderStyle.None,
            TabStop = false,
        };
        _logCard.Controls.Add(_logTitleLabel);
        _logCard.Controls.Add(_clearLogBtn);
        _logCard.Controls.Add(_logBox);

        Controls.Add(_logoBox);
        Controls.Add(_titleLabel);
        Controls.Add(_subtitleLabel);
        Controls.Add(_modeCard);
        Controls.Add(_paramCard);
        Controls.Add(_addressCard);
        Controls.Add(_actionPanel);
        Controls.Add(_statusCard);
        Controls.Add(_logCard);

        _portBox.ValueChanged += (_, _) =>
        {
            UpdateAddressPreview();
            SaveSettings();
        };
        _devicePortBox.ValueChanged += (_, _) => SaveSettings();
        _pathBox.TextChanged += (_, _) =>
        {
            UpdateAddressPreview();
            SaveSettings();
        };
        _externalUrlBox.TextChanged += (_, _) =>
        {
            UpdateAddressPreview();
            SaveSettings();
        };
        _ffmpegBox.TextChanged += (_, _) => SaveSettings();
        _deviceCombo.SelectedIndexChanged += (_, _) => SaveSettings();

        _uiBuilt = true;
    }

    private CardPanel MakeCard() => new()
    {
        BackColor = Theme.Bg,
        CardColor = Theme.Panel,
        Radius = Px(10),
    };

    private static Panel MakeRow() => new()
    {
        BackColor = Theme.Panel,
    };

    private static void ApplyModeButtonStyle(Button button, bool selected)
    {
        button.FlatStyle = FlatStyle.Flat;
        button.UseVisualStyleBackColor = false;
        button.Font = UiFont(10f, FontStyle.Bold);
        if (selected)
        {
            button.BackColor = Theme.Accent;
            button.ForeColor = Color.White;
            button.FlatAppearance.BorderColor = Theme.Accent;
            button.FlatAppearance.MouseOverBackColor = Theme.AccentHover;
            button.FlatAppearance.MouseDownBackColor = ColorTranslator.FromHtml("#2E8BE0");
        }
        else
        {
            button.BackColor = Theme.PanelAlt;
            button.ForeColor = Theme.Muted;
            button.FlatAppearance.BorderColor = Theme.Border;
            button.FlatAppearance.MouseOverBackColor = Theme.Panel;
            button.FlatAppearance.MouseDownBackColor = Theme.Input;
        }
    }

    // ───────────────────────── 布局 ─────────────────────────

    private int Px(int value) => (int)Math.Round(value * _scale);

    private static void Place(Control control, int x, int y, int w, int h)
    {
        control.Location = new Point(x, y);
        control.Size = new Size(Math.Max(1, w), Math.Max(1, h));
    }

    private void LayoutAll()
    {
        // 构造期间 SetBounds 会触发 OnResize，此时控件还没建好，直接跳过。
        if (_inLayout || _closing || !_uiBuilt)
        {
            return;
        }

        if (ClientSize.Width < 200 || ClientSize.Height < 200)
        {
            return;
        }

        _inLayout = true;
        try
        {
            var pad = Px(20);
            var contentW = ClientSize.Width - pad * 2;
            var y = Px(10);

            var logoSize = Px(46);
            var textLeft = pad;
            if (_logoBox.Visible)
            {
                Place(_logoBox, pad, y, logoSize, logoSize);
                textLeft = pad + logoSize + Px(12);
            }

            var textWidth = ClientSize.Width - textLeft - pad;
            Place(_titleLabel, textLeft, y, textWidth, Px(30));
            y += Px(30) + Px(2);
            Place(_subtitleLabel, textLeft, y, textWidth, Px(16));
            y += Px(16) + Px(8);

            Place(_modeCard, pad, y, contentW, Px(92));
            LayoutModeCard();
            y += Px(92) + Px(8);

            var paramH = Px(_mode == OutputMode.External ? 122 : _mode == OutputMode.Usb ? 92 : 62);
            Place(_paramCard, pad, y, contentW, paramH);
            LayoutParamCard();
            y += paramH + Px(8);

            Place(_addressCard, pad, y, contentW, Px(72));
            LayoutAddressCard();
            y += Px(72) + Px(8);

            Place(_actionPanel, pad, y, contentW, Px(36));
            LayoutActionPanel();
            y += Px(36) + Px(8);

            Place(_statusCard, pad, y, contentW, Px(62));
            LayoutStatusCard();
            y += Px(62) + Px(8);

            var logH = Math.Max(Px(96), ClientSize.Height - Px(12) - y);
            Place(_logCard, pad, y, contentW, logH);
            LayoutLogCard();
        }
        catch (Exception ex)
        {
            AppLog.Error("界面布局失败", ex);
        }
        finally
        {
            _inLayout = false;
        }
    }

    private void LayoutModeCard()
    {
        var pad = Px(14);
        var innerW = _modeCard.Width - pad * 2;
        if (innerW <= 0)
        {
            return;
        }

        Place(_modeTitleLabel, pad, Px(10), innerW, Px(14));

        var gap = Px(10);
        var btnW = Math.Max(Px(80), (innerW - gap * 2) / 3);
        var btnY = Px(32);
        var btnH = Px(32);
        Place(_modeUsbBtn, pad, btnY, btnW, btnH);
        Place(_modeLanBtn, pad + btnW + gap, btnY, btnW, btnH);
        Place(_modeExternalBtn, pad + (btnW + gap) * 2, btnY, btnW, btnH);

        Place(_modeHintLabel, pad, Px(72), innerW, Px(14));
    }

    private void LayoutParamCard()
    {
        var pad = Px(14);
        var innerW = _paramCard.Width - pad * 2;
        if (innerW <= 0)
        {
            return;
        }

        Place(_paramTitleLabel, pad, Px(10), innerW, Px(14));

        var rowH = Px(24);
        var gap = Px(6);
        var rowY = Px(28);

        Place(_paramRow1, pad, rowY, innerW, rowH);
        rowY += rowH + gap;

        if (_usbRow.Visible)
        {
            Place(_usbRow, pad, rowY, innerW, rowH);
            rowY += rowH + gap;
        }

        if (_extRow1.Visible)
        {
            Place(_extRow1, pad, rowY, innerW, rowH);
            rowY += rowH + gap;
        }

        if (_extRow2.Visible)
        {
            Place(_extRow2, pad, rowY, innerW, rowH);
        }

        LayoutParamRows(innerW);
    }

    private void LayoutParamRows(int innerW)
    {
        // 第一行：端口 + 流路径
        {
            var x = 0;
            Place(_portLabel, x, Px(4), Px(34), Px(16));
            x += Px(38);
            Place(_portBox, x, 0, Px(92), Px(23));
            x += Px(92) + Px(20);
            Place(_pathLabel, x, Px(4), Px(52), Px(16));
            x += Px(56);
            Place(_pathBox, x, Px(1), Px(210), Px(22));
            x += Px(210) + Px(12);
            Place(_pathHintLabel, x, Px(4), Math.Max(Px(60), innerW - x), Px(16));
        }

        // USB 行：设备 + 刷新 + 设备端口
        {
            var x = 0;
            Place(_deviceLabel, x, Px(4), Px(36), Px(16));
            x += Px(40);
            Place(_deviceCombo, x, 0, Px(300), Px(23));
            x += Px(300) + Px(12);
            Place(_refreshDevicesBtn, x, 0, Px(92), Px(23));
            x += Px(92) + Px(22);
            Place(_devicePortLabel, x, Px(4), Px(64), Px(16));
            x += Px(68);
            Place(_devicePortBox, x, 0, Px(92), Px(23));
        }

        // 外部推流：目标地址
        {
            var x = 0;
            Place(_externalUrlLabel, x, Px(4), Px(64), Px(16));
            x += Px(68);
            Place(_externalUrlBox, x, Px(1), Px(520), Px(22));
            x += Px(520) + Px(12);
            Place(_externalHintLabel, x, Px(4), Math.Max(Px(60), innerW - x), Px(16));
        }

        // 外部推流：ffmpeg 路径
        {
            var x = 0;
            Place(_ffmpegLabel, x, Px(4), Px(80), Px(16));
            x += Px(84);
            Place(_ffmpegBox, x, Px(1), Px(520), Px(22));
            x += Px(520) + Px(12);
            Place(_browseFfmpegBtn, x, 0, Px(80), Px(22));
        }
    }

    private void LayoutAddressCard()
    {
        var pad = Px(14);
        var innerW = _addressCard.Width - pad * 2;
        if (innerW <= 0)
        {
            return;
        }

        Place(_addressTitleLabel, pad, Px(10), innerW, Px(14));
        var copyW = Px(96);
        var boxW = Math.Max(Px(120), innerW - copyW - Px(10));
        Place(_addressBox, pad, Px(28), boxW, Px(34));
        Place(_copyAddressBtn, pad + boxW + Px(10), Px(30), copyW, Px(28));
    }

    private void LayoutActionPanel()
    {
        var startW = Px(150);
        var fwW = Px(160);
        var gap = Px(12);
        Place(_startBtn, 0, 0, startW, Px(36));
        Place(_firewallBtn, startW + gap, 0, fwW, Px(36));
        var hintX = startW + gap + fwW + Px(14);
        Place(_actionHintLabel, hintX, Px(10), Math.Max(Px(60), _actionPanel.Width - hintX), Px(16));
    }

    private void LayoutStatusCard()
    {
        var pad = Px(14);
        var innerW = _statusCard.Width - pad * 2;
        if (innerW <= 0)
        {
            return;
        }

        Place(_statusDot, pad, Px(10), Px(18), Px(20));
        Place(_statusText, pad + Px(20), Px(10), Math.Max(Px(60), innerW - Px(20)), Px(20));
        Place(_statsLabel, pad, Px(36), innerW, Px(16));
    }

    private void LayoutLogCard()
    {
        var pad = Px(14);
        var innerW = _logCard.Width - pad * 2;
        if (innerW <= 0)
        {
            return;
        }

        Place(_logTitleLabel, pad, Px(10), Math.Max(Px(80), innerW - Px(88)), Px(14));
        Place(_clearLogBtn, pad + innerW - Px(76), Px(7), Px(76), Px(22));
        var boxH = Math.Max(Px(40), _logCard.Height - Px(38));
        Place(_logBox, pad, Px(28), innerW, boxH);
    }

    // ───────────────────────── DPI / 生命周期 ─────────────────────────

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        try
        {
            UpdateScaleFromDpi();
            if (!_sizeInitialized)
            {
                _sizeInitialized = true;
                ClientSize = new Size(Px(900), Px(640));
                MinimumSize = new Size(Px(880), Px(620));
            }

            LayoutAll();
            ApplyDarkTitleBar();
        }
        catch (Exception ex)
        {
            AppLog.Error("初始化窗口尺寸失败", ex);
        }
    }

    /// <summary>让标题栏跟随深色主题（Windows 10 1809+ / 11；失败时静默忽略）。</summary>
    private void ApplyDarkTitleBar()
    {
        if (_darkTitleBarApplied)
        {
            return;
        }

        _darkTitleBarApplied = true;
        try
        {
            var enabled = 1;
            var hr = DwmSetWindowAttribute(Handle, 20, ref enabled, sizeof(int));
            if (hr != 0)
            {
                DwmSetWindowAttribute(Handle, 19, ref enabled, sizeof(int));
            }
        }
        catch
        {
            // 老系统没有 dwmapi / 不支持该属性，保持系统默认标题栏
        }
    }

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void UpdateScaleFromDpi()
    {
        try
        {
            var dpi = DeviceDpi;
            _scale = dpi > 0 ? dpi / 96f : 1f;
        }
        catch
        {
            _scale = 1f;
        }
    }

    private void OnDpiChangedHandler(object? sender, DpiChangedEventArgs e)
    {
        try
        {
            _scale = e.DeviceDpiNew > 0 ? e.DeviceDpiNew / 96f : 1f;
            ClientSize = new Size(Px(900), Px(640));
            LayoutAll();
        }
        catch (Exception ex)
        {
            AppLog.Warn("DPI 变化后重排界面失败：" + ex.Message);
        }
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        LayoutAll();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        try
        {
            LayoutAll();
            UpdateAddressPreview();
            UpdateActionButton();
            RefreshStatusPanel();
            RefreshStats();
            if (_mode == OutputMode.Usb && !_devicesLoaded && !_refreshingDevices)
            {
                RefreshDevices(quiet: true);
            }
        }
        catch (Exception ex)
        {
            AppLog.Error("窗口初始化失败", ex);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _closing = true;
        try
        {
            _uiTimer?.Stop();
        }
        catch
        {
            // ignore
        }

        try
        {
            AppLog.LineWritten -= OnLogLine;
        }
        catch
        {
            // ignore
        }

        SaveSettings();
        try
        {
            StopCore();
        }
        catch (Exception ex)
        {
            AppLog.Error("关闭时释放资源失败", ex);
        }

        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _closing = true;
            try
            {
                _uiTimer?.Stop();
                _uiTimer?.Dispose();
            }
            catch
            {
                // ignore
            }

            try
            {
                AppLog.LineWritten -= OnLogLine;
            }
            catch
            {
                // ignore
            }

            try
            {
                StopCore();
            }
            catch
            {
                // ignore
            }
        }

        base.Dispose(disposing);
    }

    // ───────────────────────── 设置持久化 ─────────────────────────

    private sealed class AppSettings
    {
        public string? Mode { get; set; } = "usb";
        public int Port { get; set; } = 19350;
        public string Path { get; set; } = DefaultPath;
        public int DevicePort { get; set; } = 28767;
        public string? Udid { get; set; }
        public string? FfmpegPath { get; set; }
        public string? ExternalUrl { get; set; }
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private static string SettingsFilePath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "DOUY",
        "settings.json");

    private static AppSettings LoadSettingsFromDisk()
    {
        var file = SettingsFilePath;
        if (!File.Exists(file))
        {
            return new AppSettings();
        }

        var json = File.ReadAllText(file, Encoding.UTF8);
        if (string.IsNullOrWhiteSpace(json))
        {
            return new AppSettings();
        }

        return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
    }

    private void ApplySettingsToUi(AppSettings settings)
    {
        _loadingSettings = true;
        try
        {
            _portBox.Value = Math.Clamp((decimal)settings.Port, _portBox.Minimum, _portBox.Maximum);
            _pathBox.Text = string.IsNullOrWhiteSpace(settings.Path) ? DefaultPath : settings.Path.Trim();
            _devicePortBox.Value = Math.Clamp((decimal)settings.DevicePort, _devicePortBox.Minimum, _devicePortBox.Maximum);
            _externalUrlBox.Text = settings.ExternalUrl ?? string.Empty;
            _ffmpegBox.Text = settings.FfmpegPath ?? string.Empty;
            _preferredUdid = settings.Udid;
            SelectMode(ParseMode(settings.Mode), persist: false);
        }
        catch (Exception ex)
        {
            AppLog.Warn("应用设置失败：" + ex.Message);
        }
        finally
        {
            _loadingSettings = false;
        }

        UpdateAddressPreview();
    }

    private AppSettings CollectSettings() => new()
    {
        Mode = ModeToString(_mode),
        Port = (int)_portBox.Value,
        Path = NormalizePath(_pathBox.Text),
        DevicePort = (int)_devicePortBox.Value,
        Udid = SelectedUdid() ?? _preferredUdid,
        FfmpegPath = _ffmpegBox.Text.Trim(),
        ExternalUrl = _externalUrlBox.Text.Trim(),
    };

    private void SaveSettings()
    {
        if (_loadingSettings || _portBox == null)
        {
            return;
        }

        try
        {
            var file = SettingsFilePath;
            var dir = System.IO.Path.GetDirectoryName(file);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var json = JsonSerializer.Serialize(CollectSettings(), JsonOptions);
            File.WriteAllText(file, json, new UTF8Encoding(false));
        }
        catch (Exception ex)
        {
            var now = Environment.TickCount64;
            if (now - _lastSettingsWarnTick > 10000)
            {
                _lastSettingsWarnTick = now;
                AppLog.Warn("保存设置失败：" + ex.Message);
            }
        }
    }

    // ───────────────────────── 模式 / 参数 ─────────────────────────

    private void SelectMode(OutputMode mode, bool persist)
    {
        _mode = mode;
        ApplyModeButtonStyle(_modeUsbBtn, mode == OutputMode.Usb);
        ApplyModeButtonStyle(_modeLanBtn, mode == OutputMode.LanRtmp);
        ApplyModeButtonStyle(_modeExternalBtn, mode == OutputMode.External);
        _modeHintLabel.Text = ModeHint(mode);
        _usbRow.Visible = mode == OutputMode.Usb;
        _extRow1.Visible = mode == OutputMode.External;
        _extRow2.Visible = mode == OutputMode.External;

        LayoutAll();
        UpdateAddressPreview();

        if (persist)
        {
            SaveSettings();
        }

        // 句柄未创建时先不扫描，避免结果被丢弃后卡住刷新标志（OnShown 里会补一次）。
        if (!_loadingSettings && IsHandleCreated && mode == OutputMode.Usb
            && !_devicesLoaded && !_refreshingDevices)
        {
            RefreshDevices(quiet: true);
        }
    }

    private static OutputMode ParseMode(string? value)
    {
        var text = (value ?? string.Empty).Trim().ToLowerInvariant();
        return text switch
        {
            "lan" or "lanrtmp" or "rtmp" or "局域网" => OutputMode.LanRtmp,
            "external" or "ffmpeg" or "push" or "外推" or "外部推流" => OutputMode.External,
            _ => OutputMode.Usb,
        };
    }

    private static string ModeToString(OutputMode mode) => mode switch
    {
        OutputMode.LanRtmp => "lan",
        OutputMode.External => "external",
        _ => "usb",
    };

    private static string ModeName(OutputMode mode) => mode switch
    {
        OutputMode.LanRtmp => "局域网 RTMP",
        OutputMode.External => "外部推流",
        _ => "USB 连接",
    };

    private static string ModeHint(OutputMode mode) => mode switch
    {
        OutputMode.LanRtmp => "手机与电脑连同一 WiFi，手机直接拉取下方地址，无需数据线。",
        OutputMode.External => "把收到的流用 ffmpeg 转推到外部 rtmp(s) 服务器，适合云端中转分发。",
        _ => "手机用数据线连接，经 Apple Mobile Device 服务以设备端口接收画面（OBS → PC → USB → 手机）。",
    };

    private static string NormalizePath(string? path)
    {
        var text = (path ?? string.Empty).Trim().Trim('/');
        return text.Length == 0 ? DefaultPath : text;
    }

    private static bool IsValidRtmpUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && (string.Equals(uri.Scheme, "rtmp", StringComparison.OrdinalIgnoreCase)
            || string.Equals(uri.Scheme, "rtmps", StringComparison.OrdinalIgnoreCase));

    private void UpdateAddressPreview()
    {
        if (_addressBox == null)
        {
            return;
        }

        try
        {
            var port = (int)_portBox.Value;
            var path = NormalizePath(_pathBox.Text);
            var builder = new StringBuilder();

            // live/douy → app=live, key=douy（OBS 要拆成「服务器 + 推流码」两段填）
            var slash = path.LastIndexOf('/');
            var app = slash > 0 ? path[..slash] : path;
            var streamKey = slash > 0 && slash < path.Length - 1 ? path[(slash + 1)..] : "douy";

            builder.AppendLine("========== OBS 推流配置（OBS → 本机）==========");
            builder.AppendLine($"服务器：rtmp://127.0.0.1:{port}/{app}");
            builder.AppendLine($"推流码：{streamKey}");
            builder.AppendLine();

            if (_mode == OutputMode.External)
            {
                var target = _externalUrlBox.Text.Trim();
                if (target.Length > 0)
                {
                    builder.AppendLine("转推 → " + target);
                    builder.AppendLine();
                }
            }

            if (_mode == OutputMode.Usb)
            {
                builder.AppendLine("========== USB 模式 ==========");
                builder.AppendLine($"OBS 推流后经数据线送到 iPhone（手机端选「USB 直连」，监听 {_devicePortBox.Value}）");
            }
            else
            {
                builder.AppendLine("========== 手机拉流地址（同一 WiFi）==========");
                var addresses = SafeLocalAddresses();
                if (addresses.Count == 0)
                {
                    builder.AppendLine("（未检测到有效局域网 IP，请检查 WiFi / 网线连接）");
                }
                else
                {
                    foreach (var ip in addresses)
                    {
                        builder.AppendLine($"rtmp://{ip}:{port}/{path}");
                    }
                }
            }

            _addressBox.Text = builder.ToString().TrimEnd();
        }
        catch (Exception ex)
        {
            AppLog.Warn("刷新拉流地址失败：" + ex.Message);
        }
    }

    private static List<string> SafeLocalAddresses()
    {
        var results = new List<string>();
        try
        {
            foreach (var ip in Program.LocalAddresses())
            {
                // 169.254.x.x 是 DHCP 失败时的链路本地地址，手机根本连不上，直接不显示
                if (string.IsNullOrWhiteSpace(ip)
                    || ip.StartsWith("169.254.", StringComparison.Ordinal)
                    || results.Contains(ip))
                {
                    continue;
                }

                results.Add(ip);
            }
        }
        catch (Exception ex)
        {
            AppLog.Warn("枚举本机地址失败：" + ex.Message);
        }

        // 169.254.x.x 是链路本地地址（没拿到 DHCP），排到最后，先展示真正的局域网地址。
        results.Sort((a, b) =>
        {
            var aLinkLocal = a.StartsWith("169.254.", StringComparison.Ordinal);
            var bLinkLocal = b.StartsWith("169.254.", StringComparison.Ordinal);
            if (aLinkLocal != bLinkLocal)
            {
                return aLinkLocal ? 1 : -1;
            }

            return string.CompareOrdinal(a, b);
        });

        return results;
    }

    // ───────────────────────── 日志区 ─────────────────────────

    private void FillLogFromSnapshot()
    {
        try
        {
            var snapshot = AppLog.Snapshot();
            var start = Math.Max(0, snapshot.Length - MaxLogLines);
            _logBox.Lines = snapshot[start..];
            _logLineCount = _logBox.Lines.Length;
            _logBox.SelectionStart = _logBox.TextLength;
            _logBox.ScrollToCaret();
        }
        catch (Exception ex)
        {
            AppLog.Warn("载入历史日志失败：" + ex.Message);
        }
    }

    private void OnLogLine(string line)
    {
        if (_closing || IsDisposed || string.IsNullOrEmpty(line))
        {
            return;
        }

        try
        {
            if (!IsHandleCreated)
            {
                return;
            }

            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(OnLogLine), line);
                return;
            }

            AppendLogLine(line);
        }
        catch (InvalidOperationException)
        {
            // 窗口正在销毁 / 已销毁（ObjectDisposedException 也是它的子类），忽略
        }
        catch (Exception ex)
        {
            AppLog.Warn("追加日志到界面失败：" + ex.Message);
        }
    }

    private void AppendLogLine(string line)
    {
        var text = line.Replace("\r", string.Empty);
        if (text.Length == 0)
        {
            return;
        }

        // 只有视图停留在末尾时才跟随滚动；用户往上翻（约 4 KB 之外）就不再抢滚动条。
        var follow = true;
        try
        {
            var top = _logBox.GetCharIndexFromPosition(new Point(Px(4), Px(4)));
            follow = top < 0 || top >= _logBox.TextLength - 4096;
        }
        catch
        {
            follow = true;
        }

        if (_logBox.TextLength > 0)
        {
            _logBox.AppendText(Environment.NewLine);
        }

        _logBox.AppendText(text);
        _logLineCount++;

        if (_logLineCount > MaxLogLines)
        {
            TrimLog();
            follow = true;
        }

        if (follow)
        {
            _logBox.SelectionStart = _logBox.TextLength;
            _logBox.ScrollToCaret();
        }
    }

    private void TrimLog()
    {
        try
        {
            var lines = _logBox.Lines;
            if (lines.Length <= MaxLogLines)
            {
                _logLineCount = lines.Length;
                return;
            }

            var keep = Math.Max(1, MaxLogLines - 200);
            var trimmed = lines[(lines.Length - keep)..];
            _logBox.Text = string.Join(Environment.NewLine, trimmed);
            _logLineCount = trimmed.Length;
        }
        catch (Exception ex)
        {
            AppLog.Warn("裁剪日志失败：" + ex.Message);
        }
    }

    private void ClearLog()
    {
        try
        {
            _logBox.Clear();
            _logLineCount = 0;
            AppLog.Info("日志面板已清空（历史记录仍保留在内存中）");
        }
        catch (Exception ex)
        {
            AppLog.Warn("清空日志失败：" + ex.Message);
        }
    }

    private void CopyAddress()
    {
        var text = _addressBox.Text.Trim();
        if (text.Length == 0)
        {
            ShowWarning("当前没有可复制的拉流地址。");
            return;
        }

        try
        {
            Clipboard.SetText(text);
            AppLog.Info("拉流地址已复制到剪贴板");
            _copyFlashUntil = DateTime.UtcNow.AddSeconds(1.5);
            _copyAddressBtn.Text = "已复制";
            _copyAddressBtn.BackColor = Theme.Success;
            _copyAddressBtn.ForeColor = Color.White;
            _copyAddressBtn.FlatAppearance.BorderColor = Theme.Success;
        }
        catch (Exception ex)
        {
            AppLog.Warn("复制到剪贴板失败：" + ex.Message);
            ShowWarning("复制失败，请手动选中地址复制。");
        }
    }

    // ───────────────────────── USB 设备 ─────────────────────────

    private sealed class DeviceEntry
    {
        public static readonly DeviceEntry Placeholder = new(string.Empty, string.Empty);

        public DeviceEntry(string udid, string connection)
        {
            Udid = udid;
            Connection = connection;
        }

        public string Udid { get; }
        public string Connection { get; }
        public bool IsPlaceholder => string.IsNullOrEmpty(Udid);

        public override string ToString()
        {
            if (IsPlaceholder)
            {
                return DeviceHint;
            }

            var shortId = Udid.Length > 8 ? Udid[..8] + "…" : Udid;
            var connection = string.IsNullOrWhiteSpace(Connection) ? "USB" : Connection.Trim();
            return $"{shortId}({connection})";
        }
    }

    private string? SelectedUdid() =>
        _deviceCombo.SelectedItem is DeviceEntry entry && !entry.IsPlaceholder ? entry.Udid : null;

    private void RefreshDevices(bool quiet)
    {
        if (_refreshingDevices || _closing)
        {
            return;
        }

        _refreshingDevices = true;
        _refreshDevicesBtn.Enabled = false;
        _refreshDevicesBtn.Text = "刷新中…";
        var preferred = SelectedUdid() ?? _preferredUdid ?? _settings.Udid;
        if (!quiet)
        {
            AppLog.Info("正在扫描 Apple 移动设备…");
        }

        Task.Run(() =>
        {
            var entries = new List<DeviceEntry>();
            string? error = null;
            try
            {
                using var mux = UsbMuxClient.ConnectToService();
                foreach (var device in mux.ListDevices())
                {
                    entries.Add(new DeviceEntry(device.Udid, device.ConnectionType));
                }
            }
            catch (Exception ex)
            {
                error = ex.Message;
                AppLog.Warn("扫描 USB 设备失败：" + ex.Message);
            }

            Post(() =>
            {
                _refreshingDevices = false;
                _devicesLoaded = error == null;
                _refreshDevicesBtn.Enabled = true;
                _refreshDevicesBtn.Text = "刷新设备";

                try
                {
                    _deviceCombo.BeginUpdate();
                    _deviceCombo.Items.Clear();
                    foreach (var entry in entries)
                    {
                        _deviceCombo.Items.Add(entry);
                    }

                    if (_deviceCombo.Items.Count == 0)
                    {
                        _deviceCombo.Items.Add(DeviceEntry.Placeholder);
                        _deviceCombo.SelectedIndex = 0;
                        AppLog.Warn(DeviceHint);
                        if (!quiet)
                        {
                            ShowWarning(DeviceHint);
                        }
                    }
                    else
                    {
                        var index = 0;
                        if (!string.IsNullOrEmpty(preferred))
                        {
                            for (var i = 0; i < _deviceCombo.Items.Count; i++)
                            {
                                if (_deviceCombo.Items[i] is DeviceEntry candidate && candidate.Udid == preferred)
                                {
                                    index = i;
                                    break;
                                }
                            }
                        }

                        _deviceCombo.SelectedIndex = index;
                        _preferredUdid = SelectedUdid();
                        AppLog.Info($"发现 {entries.Count} 台设备（{ModeName(_mode)}）");
                    }
                }
                catch (Exception ex)
                {
                    AppLog.Warn("更新设备列表失败：" + ex.Message);
                }
                finally
                {
                    _deviceCombo.EndUpdate();
                }
            });
        });
    }

    private void BrowseFfmpeg()
    {
        try
        {
            using var dialog = new OpenFileDialog
            {
                Title = "选择 ffmpeg.exe",
                Filter = "ffmpeg (ffmpeg.exe)|ffmpeg.exe|可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*",
                CheckFileExists = true,
                Multiselect = false,
            };

            if (dialog.ShowDialog(this) == DialogResult.OK)
            {
                _ffmpegBox.Text = dialog.FileName;
            }
        }
        catch (Exception ex)
        {
            AppLog.Warn("选择 ffmpeg 失败：" + ex.Message);
        }
    }

    // ───────────────────────── 开始 / 停止输出 ─────────────────────────

    private sealed record StartRequest(
        OutputMode Mode,
        int Port,
        string Path,
        int DevicePort,
        string? Udid,
        string ExternalUrl,
        string FfmpegPath);

    private void OnStartStopClick()
    {
        if (_busy)
        {
            return;
        }

        if (_running)
        {
            StopOutput();
        }
        else
        {
            StartOutput();
        }
    }

    private void StartOutput()
    {
        if (_busy || _running)
        {
            return;
        }

        var port = (int)_portBox.Value;
        var path = NormalizePath(_pathBox.Text);

        string? udid = null;
        if (_mode == OutputMode.Usb)
        {
            udid = SelectedUdid();
            if (string.IsNullOrEmpty(udid))
            {
                ShowWarning("请先点「刷新设备」并选择一台 iPhone。");
                return;
            }
        }

        var externalUrl = _externalUrlBox.Text.Trim();
        if (_mode == OutputMode.External)
        {
            if (!IsValidRtmpUrl(externalUrl))
            {
                ShowWarning("请填写有效的外部推流地址（以 rtmp:// 或 rtmps:// 开头）。");
                _externalUrlBox.Focus();
                return;
            }
        }

        var request = new StartRequest(
            _mode,
            port,
            path,
            (int)_devicePortBox.Value,
            udid,
            externalUrl,
            _ffmpegBox.Text.Trim());

        SaveSettings();

        _busy = true;
        _busyStart = true;
        UpdateActionButton();
        AppLog.Info($"开始输出 · {ModeName(request.Mode)} · RTMP 端口 {port} · 路径 {path}");

        Task.Run(() =>
        {
            Exception? failure = null;
            try
            {
                StartCore(request);
            }
            catch (Exception ex)
            {
                failure = ex;
                AppLog.Error("启动输出失败", ex);
                StopCore();
            }

            Post(() =>
            {
                _busy = false;
                _running = failure == null;
                UpdateActionButton();
                RefreshStatusPanel();
                RefreshStats();
                UpdateAddressPreview();
                if (failure != null)
                {
                    ShowWarning("启动输出失败：" + failure.Message);
                }
                else
                {
                    AppLog.Info("输出已启动");
                }
            });
        });
    }

    private void StartCore(StartRequest request)
    {
        if (_closing)
        {
            throw new OperationCanceledException("窗口正在关闭，已取消启动");
        }

        string? ffmpegPath = null;
        if (request.Mode == OutputMode.External)
        {
            ffmpegPath = ResolveFfmpeg(request.FfmpegPath);
            if (ffmpegPath == null)
            {
                throw new InvalidOperationException("未找到 ffmpeg.exe，外部推流不可用");
            }
        }

        var hub = new MediaHub();
        var server = new RtmpServer();
        lock (_sync)
        {
            _hub = hub;
            _server = server;
        }

        hub.Attach(server);
        server.ViewerCountChanged += count => AppLog.Info($"观众数量变为 {count}");
        server.Start(request.Port, request.Path);
        AppLog.Info($"RTMP 服务已监听 :{request.Port}/{request.Path}");

        if (_closing)
        {
            throw new OperationCanceledException("窗口正在关闭，已取消启动");
        }

        if (request.Mode == OutputMode.Usb)
        {
            var bridge = new UsbBridge(hub, request.Udid, request.DevicePort, null);
            lock (_sync)
            {
                _bridge = bridge;
            }

            bridge.Start();
        }
        else if (request.Mode == OutputMode.External)
        {
            var process = StartFfmpeg(ffmpegPath!, request);
            lock (_sync)
            {
                _ffmpeg = process;
            }
        }

        if (_closing)
        {
            StopCore();
            throw new OperationCanceledException("窗口正在关闭，已取消启动");
        }
    }

    private void StopOutput()
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        _busyStart = false;
        _running = false;
        UpdateActionButton();
        RefreshStatusPanel();
        AppLog.Info("正在停止输出…");

        Task.Run(() =>
        {
            try
            {
                StopCore();
            }
            catch (Exception ex)
            {
                AppLog.Error("停止输出失败", ex);
            }

            Post(() =>
            {
                _busy = false;
                _running = false;
                UpdateActionButton();
                RefreshStatusPanel();
                RefreshStats();
                AppLog.Info("输出已停止");
            });
        });
    }

    /// <summary>停 bridge → 停 ffmpeg → 停 RTMP 服务 → hub.Detach()。可在任意线程调用。</summary>
    private void StopCore()
    {
        UsbBridge? bridge;
        IRtmpServer? server;
        Process? ffmpeg;
        MediaHub? hub;

        lock (_sync)
        {
            bridge = _bridge;
            _bridge = null;
            ffmpeg = _ffmpeg;
            _ffmpeg = null;
            server = _server;
            _server = null;
            hub = _hub;
            _hub = null;
        }

        if (bridge != null)
        {
            try
            {
                bridge.Stop();
            }
            catch (Exception ex)
            {
                AppLog.Warn("停止 USB 桥失败：" + ex.Message);
            }

            try
            {
                bridge.Dispose();
            }
            catch
            {
                // ignore
            }
        }

        if (ffmpeg != null)
        {
            try
            {
                if (!ffmpeg.HasExited)
                {
                    ffmpeg.Kill(entireProcessTree: true);
                    if (!ffmpeg.WaitForExit(2000))
                    {
                        AppLog.Warn("ffmpeg 未能及时退出");
                    }
                }
            }
            catch (Exception ex)
            {
                AppLog.Warn("停止 ffmpeg 失败：" + ex.Message);
            }
            finally
            {
                try
                {
                    ffmpeg.Dispose();
                }
                catch
                {
                    // ignore
                }
            }
        }

        if (server != null)
        {
            try
            {
                server.Stop();
            }
            catch (Exception ex)
            {
                AppLog.Warn("停止 RTMP 服务失败：" + ex.Message);
            }

            try
            {
                server.Dispose();
            }
            catch
            {
                // ignore
            }
        }

        if (hub != null)
        {
            try
            {
                hub.Detach();
            }
            catch (Exception ex)
            {
                AppLog.Warn("解除媒体订阅失败：" + ex.Message);
            }

            try
            {
                hub.Dispose();
            }
            catch
            {
                // ignore
            }
        }
    }

    // ───────────────────────── ffmpeg 转推 ─────────────────────────

    private static string? ResolveFfmpeg(string configured)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            var trimmed = configured.Trim().Trim('"');
            if (File.Exists(trimmed))
            {
                return trimmed;
            }

            AppLog.Warn($"指定的 ffmpeg 不存在：{trimmed}，改为自动查找");
        }

        foreach (var dir in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
        {
            try
            {
                var candidate = System.IO.Path.Combine(dir, "ffmpeg.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch
            {
                // ignore
            }
        }

        var pathVariable = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrEmpty(pathVariable))
        {
            foreach (var dir in pathVariable.Split(System.IO.Path.PathSeparator))
            {
                if (string.IsNullOrWhiteSpace(dir))
                {
                    continue;
                }

                try
                {
                    var candidate = System.IO.Path.Combine(dir.Trim().Trim('"'), "ffmpeg.exe");
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }
                catch
                {
                    // ignore
                }
            }
        }

        return null;
    }

    private Process StartFfmpeg(string ffmpegPath, StartRequest request)
    {
        var source = $"rtmp://127.0.0.1:{request.Port}/{request.Path}";
        var startInfo = new ProcessStartInfo
        {
            FileName = ffmpegPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
        };

        startInfo.ArgumentList.Add("-hide_banner");
        startInfo.ArgumentList.Add("-loglevel");
        startInfo.ArgumentList.Add("warning");
        startInfo.ArgumentList.Add("-i");
        startInfo.ArgumentList.Add(source);
        startInfo.ArgumentList.Add("-c");
        startInfo.ArgumentList.Add("copy");
        startInfo.ArgumentList.Add("-f");
        startInfo.ArgumentList.Add("flv");
        startInfo.ArgumentList.Add(request.ExternalUrl);

        AppLog.Info($"启动 ffmpeg：{source} → {request.ExternalUrl}");

        var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true,
        };

        process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                AppLog.Warn("[ffmpeg] " + args.Data);
            }
        };
        process.OutputDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                AppLog.Info("[ffmpeg] " + args.Data);
            }
        };
        process.Exited += (_, _) =>
        {
            var code = -1;
            try
            {
                code = process.ExitCode;
            }
            catch
            {
                // ignore
            }

            // 主动停止时 StopCore 会先把字段置空，据此区分「被我们杀掉」和「自己挂了」。
            var intentional = false;
            lock (_sync)
            {
                intentional = !ReferenceEquals(_ffmpeg, process);
            }

            if (intentional)
            {
                AppLog.Info($"[ffmpeg] 已停止（退出码 {code}）");
            }
            else
            {
                AppLog.Warn($"[ffmpeg] 意外退出（退出码 {code}），外部转推中断");
            }
        };

        if (!process.Start())
        {
            process.Dispose();
            throw new InvalidOperationException("无法启动 ffmpeg.exe");
        }

        process.BeginErrorReadLine();
        process.BeginOutputReadLine();
        return process;
    }

    // ───────────────────────── 防火墙 ─────────────────────────

    private void FixFirewall()
    {
        if (_closing)
        {
            return;
        }

        var port = (int)_portBox.Value;
        _firewallBtn.Enabled = false;
        AppLog.Info($"正在添加/更新防火墙入站规则（TCP {port}），需要管理员权限确认…");

        Task.Run(() =>
        {
            var ok = TryFixFirewall(port, out var message);
            if (ok)
            {
                AppLog.Info(message);
            }
            else
            {
                AppLog.Warn(message);
            }

            Post(() =>
            {
                _firewallBtn.Enabled = true;
                try
                {
                    MessageBox.Show(
                        this,
                        message,
                        AppTitle,
                        MessageBoxButtons.OK,
                        ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
                }
                catch
                {
                    // ignore
                }
            });
        });
    }

    private static bool TryFixFirewall(int port, out string message)
    {
        try
        {
            /*
             * 规则名必须是纯 ASCII：netsh 是控制台老工具，中文规则名在部分系统上会出现
             * "命令返回成功但 show rule 找不到规则" 的假失败（编码不一致）。
             * 同时顺手清掉旧版本用中文名建的规则，避免重复规则。
             */
            var deleteOwn = $"netsh advfirewall firewall delete rule name=\"{FirewallRuleName}\" >nul 2>&1";
            var deleteLegacy = $"netsh advfirewall firewall delete rule name=\"{FirewallRuleLegacyName}\" >nul 2>&1";
            var add = $"netsh advfirewall firewall add rule name=\"{FirewallRuleName}\" dir=in action=allow protocol=TCP localport={port} profile=any enable=yes";
            var arguments = $"/c {deleteOwn} & {deleteLegacy} & {add}";

            var startInfo = new ProcessStartInfo("cmd.exe", arguments)
            {
                UseShellExecute = true,
                Verb = "runas",
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };

            using var process = Process.Start(startInfo);
            if (process == null)
            {
                message = "无法启动 netsh：系统拒绝了管理员权限提升。";
                return false;
            }

            if (!process.WaitForExit(60000))
            {
                message = "netsh 执行超时，防火墙规则可能未生效，请手动检查 Windows 防火墙。";
                return false;
            }

            if (FirewallRuleExists())
            {
                message = $"防火墙入站规则已就绪：TCP {port}\n规则名：{FirewallRuleName}";
                return true;
            }

            message = "自动添加防火墙规则未成功。\n\n" +
                      "请用【管理员】PowerShell 手动执行这一行：\n\n" +
                      $"netsh advfirewall firewall add rule name=\"{FirewallRuleName}\" dir=in action=allow protocol=TCP localport={port} profile=any\n\n" +
                      "（局域网模式必须放行该端口，否则手机连不上。USB 模式不受影响。）";
            return false;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            message = "已取消管理员授权，防火墙规则未修改。";
            return false;
        }
        catch (Exception ex)
        {
            message = "修复访问权限失败：" + ex.Message;
            return false;
        }
    }

    private static bool FirewallRuleExists()
    {
        try
        {
            var startInfo = new ProcessStartInfo(
                "netsh",
                $"advfirewall firewall show rule name=\"{FirewallRuleName}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };

            using var process = Process.Start(startInfo);
            if (process == null)
            {
                return false;
            }

            // 只需退出码，输出直接丢弃（netsh 使用控制台代码页，这里不做解析）。
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            if (!process.WaitForExit(5000))
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch
                {
                    // ignore
                }

                return false;
            }

            return process.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    // ───────────────────────── 状态 / 统计 ─────────────────────────

    private void OnUiTick(object? sender, EventArgs e)
    {
        if (_closing)
        {
            return;
        }

        try
        {
            RefreshStatusPanel();
            RefreshStats();
            UpdateActionButton();
            RestoreCopyButton();
        }
        catch (Exception ex)
        {
            AppLog.Error("刷新界面状态失败", ex);
        }
    }

    private void RestoreCopyButton()
    {
        if (_copyFlashUntil == DateTime.MinValue || DateTime.UtcNow < _copyFlashUntil)
        {
            return;
        }

        _copyFlashUntil = DateTime.MinValue;
        _copyAddressBtn.Text = "复制地址";
        _copyAddressBtn.BackColor = Theme.PanelAlt;
        _copyAddressBtn.ForeColor = Theme.Text;
        _copyAddressBtn.FlatAppearance.BorderColor = Theme.Border;
    }

    private void RefreshStatusPanel()
    {
        if (_statusText == null || _closing)
        {
            return;
        }

        var (text, color) = ComputeStatus();
        if (!string.Equals(_statusText.Text, text, StringComparison.Ordinal))
        {
            _statusText.Text = text;
        }

        if (_statusText.ForeColor != color)
        {
            _statusText.ForeColor = color;
            _statusDot.ForeColor = color;
        }
    }

    private (string Text, Color Color) ComputeStatus()
    {
        if (_closing)
        {
            return ("正在关闭…", Theme.Muted);
        }

        if (_busy)
        {
            return _busyStart ? ("正在启动…", Theme.Warning) : ("正在停止…", Theme.Warning);
        }

        if (!_running)
        {
            return ("未开始输出", Theme.Muted);
        }

        try
        {
            switch (_mode)
            {
                case OutputMode.Usb:
                {
                    var bridge = _bridge;
                    if (bridge == null)
                    {
                        return ("USB 未连接", Theme.Warning);
                    }

                    return bridge.State switch
                    {
                        UsbBridgeState.Streaming => ("USB 输出中", Theme.Success),
                        UsbBridgeState.Handshaking => ("正在与手机握手…", Theme.Warning),
                        UsbBridgeState.WaitingPhone => ("等待手机通过 USB 连接", Theme.Warning),
                        UsbBridgeState.Error => ("USB 连接出错", Theme.Danger),
                        _ => ("USB 未连接", Theme.Muted),
                    };
                }

                case OutputMode.External:
                {
                    var server = _server;
                    if (server == null)
                    {
                        return ("未开始输出", Theme.Muted);
                    }

                    var ffmpegAlive = false;
                    var process = _ffmpeg;
                    if (process != null)
                    {
                        try
                        {
                            ffmpegAlive = !process.HasExited;
                        }
                        catch
                        {
                            ffmpegAlive = false;
                        }
                    }

                    if (server.State == RtmpServerState.Publishing)
                    {
                        return ffmpegAlive
                            ? ("正在转推到外部服务器", Theme.Success)
                            : ("已收到推流，但 ffmpeg 未运行", Theme.Danger);
                    }

                    return ("已监听，等待 OBS 推流", Theme.Warning);
                }

                default:
                {
                    var server = _server;
                    if (server == null)
                    {
                        return ("未开始输出", Theme.Muted);
                    }

                    return server.State switch
                    {
                        RtmpServerState.Publishing => ($"正在直播 · 观众 {SafeViewers(server)}", Theme.Success),
                        RtmpServerState.Listening => ("已监听，等待 OBS 推流", Theme.Warning),
                        _ => ("未开始输出", Theme.Muted),
                    };
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Error("读取输出状态失败", ex);
            return ("状态未知", Theme.Danger);
        }
    }

    private static int SafeViewers(IRtmpServer server)
    {
        try
        {
            return server.ViewerCount;
        }
        catch
        {
            return 0;
        }
    }

    private void RefreshStats()
    {
        if (_statsLabel == null || _closing)
        {
            return;
        }

        var hub = _hub;
        var server = _server;
        var bridge = _bridge;

        long video = 0;
        long audio = 0;
        var viewers = 0;

        if (hub != null)
        {
            try
            {
                video = hub.VideoFrames;
                audio = hub.AudioFrames;
            }
            catch
            {
                // ignore
            }
        }

        if (server != null)
        {
            viewers = SafeViewers(server);
        }

        var parts = new List<string>(6)
        {
            $"视频 {video} 帧",
            $"音频 {audio} 帧",
            $"观众 {viewers}",
        };

        if (bridge != null)
        {
            long sent = 0;
            long bytes = 0;
            long dropped = 0;
            try
            {
                sent = bridge.FramesSent;
                bytes = bridge.BytesSent;
                dropped = bridge.Dropped;
            }
            catch
            {
                // ignore
            }

            parts.Add($"USB 发送 {sent} 帧 / {FormatBytes(bytes)}");
            parts.Add($"丢弃 {dropped}");
        }
        else
        {
            parts.Add("丢弃 0");
        }

        var text = string.Join(" · ", parts);
        if (!string.Equals(_statsLabel.Text, text, StringComparison.Ordinal))
        {
            _statsLabel.Text = text;
        }
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes >= 1024L * 1024 * 1024)
        {
            return $"{bytes / 1073741824.0:F1} GB";
        }

        if (bytes >= 1024L * 1024)
        {
            return $"{bytes / 1048576.0:F1} MB";
        }

        if (bytes >= 1024L)
        {
            return $"{bytes / 1024.0:F1} KB";
        }

        return $"{bytes} B";
    }

    // ───────────────────────── 操作按钮 / 通用 ─────────────────────────

    private void UpdateActionButton()
    {
        if (_startBtn == null || _closing)
        {
            return;
        }

        if (_busy)
        {
            _startBtn.Enabled = false;
            _startBtn.Text = _busyStart ? "正在启动…" : "正在停止…";
            _startBtn.BackColor = Theme.PanelAlt;
            _startBtn.ForeColor = Theme.Muted;
            _startBtn.FlatAppearance.BorderColor = Theme.Border;
            SetConfigurationEnabled(false);
            return;
        }

        _startBtn.Enabled = true;
        if (_running)
        {
            _startBtn.Text = "停止输出";
            _startBtn.BackColor = Theme.Stop;
            _startBtn.ForeColor = Color.White;
            _startBtn.FlatAppearance.BorderColor = Theme.Stop;
            _startBtn.FlatAppearance.MouseOverBackColor = ColorTranslator.FromHtml("#D04A38");
            _startBtn.FlatAppearance.MouseDownBackColor = ColorTranslator.FromHtml("#A0301F");
        }
        else
        {
            _startBtn.Text = "开始输出";
            _startBtn.BackColor = Theme.Accent;
            _startBtn.ForeColor = Color.White;
            _startBtn.FlatAppearance.BorderColor = Theme.Accent;
            _startBtn.FlatAppearance.MouseOverBackColor = Theme.AccentHover;
            _startBtn.FlatAppearance.MouseDownBackColor = ColorTranslator.FromHtml("#2E8BE0");
        }

        SetConfigurationEnabled(!_running);
    }

    private void SetConfigurationEnabled(bool enabled)
    {
        _modeUsbBtn.Enabled = enabled;
        _modeLanBtn.Enabled = enabled;
        _modeExternalBtn.Enabled = enabled;
        _portBox.Enabled = enabled;
        _deviceCombo.Enabled = enabled;
        _refreshDevicesBtn.Enabled = enabled && !_refreshingDevices;
        _devicePortBox.Enabled = enabled;
        _externalUrlBox.Enabled = enabled;
        _ffmpegBox.Enabled = enabled;
        _browseFfmpegBtn.Enabled = enabled;
    }

    private void Post(Action action)
    {
        if (_closing || IsDisposed || !IsHandleCreated)
        {
            return;
        }

        try
        {
            BeginInvoke(action);
        }
        catch (InvalidOperationException)
        {
            // 窗口正在销毁 / 已销毁（ObjectDisposedException 也是它的子类），忽略
        }
    }

    private void ShowWarning(string message)
    {
        AppLog.Warn(message);
        if (_closing || IsDisposed)
        {
            return;
        }

        try
        {
            MessageBox.Show(this, message, AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        catch
        {
            // ignore
        }
    }

    // ───────────────────────── 深色原生控件的外壳 ─────────────────────────

    /// <summary>
    /// 深色 ComboBox：原生 ComboBox 关闭态固定画成系统白底，这里在原生绘制之后再覆盖一遍
    /// （背景 / 边框 / 箭头 / 选中文字），下拉列表项由 DrawItem 负责。
    /// </summary>
    private sealed class DarkComboBox : ComboBox
    {
        private const int WmPaint = 0x000F;
        private const int WmPrintClient = 0x0318;

        public DarkComboBox()
        {
            DropDownStyle = ComboBoxStyle.DropDownList;
            DrawMode = DrawMode.OwnerDrawFixed;
            FlatStyle = FlatStyle.Flat;
            BackColor = Theme.Input;
            ForeColor = Theme.Text;
            Font = UiFont(9f);
            ItemHeight = Math.Max(16, Font.Height + 2);
            MaxDropDownItems = 12;
            IntegralHeight = false;
            DrawItem += OnDrawItem;
        }

        private int ArrowWidth => Math.Max(18, Font.Height + 4);

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);

            // 绘制完成后再覆盖一次，得到稳定的深色外观（WM_PRINTCLIENT 覆盖 DrawToBitmap 场景）。
            try
            {
                if (m.Msg == WmPaint)
                {
                    using var graphics = Graphics.FromHwnd(Handle);
                    PaintClosedState(graphics);
                }
                else if (m.Msg == WmPrintClient && m.WParam != IntPtr.Zero)
                {
                    using var graphics = Graphics.FromHdc(m.WParam);
                    PaintClosedState(graphics);
                }
            }
            catch
            {
                // 自绘失败时保持系统默认外观，绝不让消息循环崩掉
            }
        }

        private void PaintClosedState(Graphics graphics)
        {
            var width = ClientSize.Width;
            var height = ClientSize.Height;
            if (width <= 0 || height <= 0)
            {
                return;
            }

            using (var background = new SolidBrush(BackColor))
            {
                graphics.FillRectangle(background, 0, 0, width, height);
            }

            using (var border = new Pen(Enabled ? Theme.Border : Theme.PanelAlt))
            {
                graphics.DrawRectangle(border, 0, 0, Math.Max(1, width - 1), Math.Max(1, height - 1));
            }

            var arrowWidth = ArrowWidth;
            var arrowRect = new Rectangle(width - arrowWidth - 1, 1, arrowWidth, Math.Max(1, height - 2));
            using (var separator = new Pen(Theme.Border))
            {
                graphics.DrawLine(separator, arrowRect.X, 1, arrowRect.X, height - 2);
            }

            using (var arrow = new SolidBrush(Enabled ? Theme.Muted : Theme.PanelAlt))
            {
                var cx = arrowRect.X + arrowRect.Width / 2;
                var cy = arrowRect.Y + arrowRect.Height / 2;
                var half = Math.Max(3, Font.Height / 5);
                graphics.FillPolygon(arrow, new[]
                {
                    new Point(cx - half, cy - half / 2),
                    new Point(cx + half, cy - half / 2),
                    new Point(cx, cy + half),
                });
            }

            var textRect = new Rectangle(4, 0, Math.Max(1, width - arrowWidth - 6), height);
            TextRenderer.DrawText(
                graphics,
                Text ?? string.Empty,
                Font,
                textRect,
                Enabled ? ForeColor : Theme.Muted,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter
                | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }

        private void OnDrawItem(object? sender, DrawItemEventArgs e)
        {
            var selected = (e.State & DrawItemState.Selected) != 0;
            using (var background = new SolidBrush(selected ? Theme.Accent : Theme.Input))
            {
                e.Graphics.FillRectangle(background, e.Bounds);
            }

            if (e.Index < 0 || e.Index >= Items.Count)
            {
                return;
            }

            var rect = new Rectangle(
                e.Bounds.X + 4,
                e.Bounds.Y,
                Math.Max(1, e.Bounds.Width - 4),
                e.Bounds.Height);
            TextRenderer.DrawText(
                e.Graphics,
                Items[e.Index]?.ToString() ?? string.Empty,
                Font,
                rect,
                selected ? Color.White : Theme.Text,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter
                | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }

    /// <summary>
    /// 深色 NumericUpDown：隐藏系统白色上下箭头，自绘深色箭头并保留点击 / 滚轮 / 键盘步进。
    /// </summary>
    private sealed class DarkNumericUpDown : NumericUpDown
    {
        private bool _hoverUp;
        private bool _hoverDown;
        private bool _tuning;

        public DarkNumericUpDown()
        {
            BorderStyle = BorderStyle.FixedSingle;
            BackColor = Theme.Input;
            ForeColor = Theme.Text;
            Font = UiFont(9f);
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        private int ButtonWidth => Math.Max(16, Font.Height + 4);

        private Rectangle UpRect => new(
            ClientSize.Width - ButtonWidth,
            1,
            ButtonWidth - 1,
            Math.Max(1, (ClientSize.Height - 2) / 2));

        private Rectangle DownRect
        {
            get
            {
                var top = 1 + (ClientSize.Height - 2) / 2;
                return new Rectangle(
                    ClientSize.Width - ButtonWidth,
                    top,
                    ButtonWidth - 1,
                    Math.Max(1, ClientSize.Height - 1 - top));
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            TuneChildren();
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            TuneChildren();
        }

        private void TuneChildren()
        {
            if (_tuning)
            {
                return;
            }

            _tuning = true;
            try
            {
                foreach (Control child in Controls)
                {
                    if (child.GetType().Name.Contains("UpDownButtons", StringComparison.Ordinal))
                    {
                        child.Visible = false;
                    }
                    else if (child is TextBoxBase editor)
                    {
                        editor.Bounds = new Rectangle(
                            1,
                            1,
                            Math.Max(10, ClientSize.Width - ButtonWidth - 1),
                            Math.Max(10, ClientSize.Height - 2));
                    }
                }
            }
            finally
            {
                _tuning = false;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);

            var graphics = e.Graphics;
            var width = ClientSize.Width;
            var height = ClientSize.Height;
            var buttonWidth = ButtonWidth;
            if (width <= buttonWidth + 4 || height < 8)
            {
                return;
            }

            using (var background = new SolidBrush(BackColor))
            {
                graphics.FillRectangle(background, width - buttonWidth, 1, buttonWidth, height - 2);
            }

            using (var separator = new Pen(Enabled ? Theme.Border : Theme.PanelAlt))
            {
                graphics.DrawLine(separator, width - buttonWidth, 1, width - buttonWidth, height - 2);
            }

            DrawArrow(graphics, UpRect, up: true, highlight: _hoverUp);
            DrawArrow(graphics, DownRect, up: false, highlight: _hoverDown);
        }

        private void DrawArrow(Graphics graphics, Rectangle rect, bool up, bool highlight)
        {
            if (highlight)
            {
                using var hover = new SolidBrush(Theme.PanelAlt);
                graphics.FillRectangle(hover, rect);
            }

            using var brush = new SolidBrush(Enabled ? Theme.Muted : Theme.PanelAlt);
            var cx = rect.X + rect.Width / 2;
            var cy = rect.Y + rect.Height / 2;
            var half = Math.Max(3, Font.Height / 6);
            var points = up
                ? new[]
                {
                    new Point(cx - half, cy + half / 2),
                    new Point(cx + half, cy + half / 2),
                    new Point(cx, cy - half),
                }
                : new[]
                {
                    new Point(cx - half, cy - half / 2),
                    new Point(cx + half, cy - half / 2),
                    new Point(cx, cy + half),
                };
            graphics.FillPolygon(brush, points);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            var up = UpRect.Contains(e.Location);
            var down = DownRect.Contains(e.Location);
            if (up != _hoverUp || down != _hoverDown)
            {
                _hoverUp = up;
                _hoverDown = down;
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (_hoverUp || _hoverDown)
            {
                _hoverUp = false;
                _hoverDown = false;
                Invalidate();
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                if (UpRect.Contains(e.Location))
                {
                    Focus();
                    UpButton();
                    return;
                }

                if (DownRect.Contains(e.Location))
                {
                    Focus();
                    DownButton();
                    return;
                }
            }

            base.OnMouseDown(e);
        }
    }

    private static Label MakeLabel(string text, float size, Color color, bool bold = false, Color? back = null) =>
        new()
        {
            Text = text,
            AutoSize = false,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = color,
            BackColor = back ?? Theme.Panel,
            Font = UiFont(size, bold ? FontStyle.Bold : FontStyle.Regular),
            Margin = Padding.Empty,
        };

    private static TextBox MakeTextBox(string text, bool readOnly, bool multiline = false, string? placeholder = null)
    {
        var box = new TextBox
        {
            Text = text,
            ReadOnly = readOnly,
            Multiline = multiline,
            BorderStyle = BorderStyle.FixedSingle,
            BackColor = Theme.Input,
            ForeColor = Theme.Text,
            Font = UiFont(9f),
            WordWrap = false,
            ScrollBars = multiline ? ScrollBars.Vertical : ScrollBars.None,
        };

        if (!string.IsNullOrEmpty(placeholder))
        {
            box.PlaceholderText = placeholder;
        }

        return box;
    }

    private static DarkNumericUpDown MakeNumeric(decimal value, decimal min, decimal max) =>
        new()
        {
            Minimum = min,
            Maximum = max,
            Value = Math.Clamp(value, min, max),
            BorderStyle = BorderStyle.FixedSingle,
            BackColor = Theme.Input,
            ForeColor = Theme.Text,
            Font = UiFont(9f),
            TextAlign = HorizontalAlignment.Left,
        };

    private static Button MakeButton(string text, bool primary = false, float size = 9f)
    {
        var button = new Button
        {
            Text = text,
            FlatStyle = FlatStyle.Flat,
            UseVisualStyleBackColor = false,
            BackColor = primary ? Theme.Accent : Theme.PanelAlt,
            ForeColor = primary ? Color.White : Theme.Text,
            Font = UiFont(size, primary ? FontStyle.Bold : FontStyle.Regular),
            Cursor = Cursors.Hand,
        };

        button.FlatAppearance.BorderSize = 1;
        button.FlatAppearance.BorderColor = primary ? Theme.Accent : Theme.Border;
        button.FlatAppearance.MouseOverBackColor = primary ? Theme.AccentHover : Theme.Panel;
        button.FlatAppearance.MouseDownBackColor = primary
            ? ColorTranslator.FromHtml("#2E8BE0")
            : Theme.Input;
        return button;
    }

    private static Font UiFont(float size, FontStyle style = FontStyle.Regular) =>
        new("Microsoft YaHei UI", size, style, GraphicsUnit.Point);

    private static Font LogFont(float size) =>
        new("Consolas", size, FontStyle.Regular, GraphicsUnit.Point);
}

/// <summary>颜色表（深色主题）。</summary>
internal static class Theme
{
    public static readonly Color Bg = ColorTranslator.FromHtml("#1E1F22");
    public static readonly Color Panel = ColorTranslator.FromHtml("#2B2D31");
    public static readonly Color PanelAlt = ColorTranslator.FromHtml("#34373C");
    public static readonly Color Input = ColorTranslator.FromHtml("#1B1C1F");
    public static readonly Color Border = ColorTranslator.FromHtml("#3A3D42");
    public static readonly Color Text = ColorTranslator.FromHtml("#E6E6E6");
    public static readonly Color Muted = ColorTranslator.FromHtml("#9AA0A6");
    public static readonly Color Dim = ColorTranslator.FromHtml("#8E9297");
    public static readonly Color Accent = ColorTranslator.FromHtml("#3AA0FF");
    public static readonly Color AccentHover = ColorTranslator.FromHtml("#57B0FF");
    public static readonly Color Success = ColorTranslator.FromHtml("#35C759");
    public static readonly Color Warning = ColorTranslator.FromHtml("#FF9F0A");
    public static readonly Color Danger = ColorTranslator.FromHtml("#FF453A");
    public static readonly Color Stop = ColorTranslator.FromHtml("#C0392B");
    public static readonly Color LogBg = ColorTranslator.FromHtml("#0E0F11");
}

/// <summary>圆角卡片面板（自绘，无图片资源）。</summary>
internal sealed class CardPanel : Panel
{
    private Color _cardColor = Theme.Panel;

    public CardPanel()
    {
        SetStyle(
            ControlStyles.AllPaintingInWmPaint
            | ControlStyles.OptimizedDoubleBuffer
            | ControlStyles.UserPaint
            | ControlStyles.ResizeRedraw,
            true);
        BackColor = Theme.Bg;
    }

    public Color CardColor
    {
        get => _cardColor;
        set
        {
            if (_cardColor == value)
            {
                return;
            }

            _cardColor = value;
            Invalidate();
        }
    }

    public int Radius { get; set; } = 10;

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var graphics = e.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;

        var rect = new Rectangle(0, 0, Width - 1, Height - 1);
        if (rect.Width <= 2 || rect.Height <= 2)
        {
            return;
        }

        using var path = RoundedRect(rect, Radius);
        using var fill = new SolidBrush(_cardColor);
        graphics.FillPath(fill, path);
        using var pen = new Pen(Theme.Border, 1f);
        graphics.DrawPath(pen, path);
    }

    private static GraphicsPath RoundedRect(Rectangle rect, int radius)
    {
        var path = new GraphicsPath();
        var diameter = Math.Max(2, radius * 2);
        diameter = Math.Min(diameter, Math.Min(rect.Width, rect.Height));

        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
