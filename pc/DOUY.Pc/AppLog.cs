using System.Text;

namespace DOUY.Pc;

/// <summary>
/// 全局日志（线程安全，同时给 UI 和 控制台 用）。
/// </summary>
public static class AppLog
{
    private static readonly object Gate = new();
    private static readonly List<string> Lines = new(2048);
    private static bool _echoConsole = true;

    /// <summary>每写入一行触发一次（UI 线程外调用，注意 Invoke）。</summary>
    public static event Action<string>? LineWritten;

    public static bool EchoConsole
    {
        get => _echoConsole;
        set => _echoConsole = value;
    }

    public static void Info(string message) => Write("INFO", message, null);
    public static void Warn(string message) => Write("WARN", message, null);
    public static void Error(string message, Exception? ex = null) => Write("ERR ", message, ex);

    public static string[] Snapshot()
    {
        lock (Gate)
        {
            return Lines.ToArray();
        }
    }

    private static void Write(string level, string message, Exception? ex)
    {
        var line = new StringBuilder()
            .Append(DateTime.Now.ToString("HH:mm:ss.fff"))
            .Append(' ')
            .Append(level)
            .Append(' ')
            .Append(message);
        if (ex != null)
        {
            line.Append(" -> ").Append(ex.GetType().Name).Append(": ").Append(ex.Message);
        }

        var text = line.ToString();
        lock (Gate)
        {
            Lines.Add(text);
            if (Lines.Count > 4000)
            {
                Lines.RemoveRange(0, 1000);
            }
        }

        if (_echoConsole)
        {
            try
            {
                Console.WriteLine(text);
            }
            catch
            {
                // 无控制台 / 管道已关闭时忽略
            }
        }

        WriteToFile(text);

        try
        {
            LineWritten?.Invoke(text);
        }
        catch
        {
            // 日志本身的异常一律吞掉
        }
    }

    // ───────────────────────── 日志落盘 ─────────────────────────

    /// <summary>
    /// 日志文件路径：优先写 exe 同目录的 logs\douy.log（最直观、一定可读），
    /// 目录不可写时回退到 %APPDATA%\DOUY\douy.log，再回退到临时目录。
    /// </summary>
    public static string LogFilePath { get; } = BuildLogPath();

    private static string BuildLogPath()
    {
        // 1) exe 同目录
        try
        {
            var baseDir = AppContext.BaseDirectory;
            if (!string.IsNullOrWhiteSpace(baseDir))
            {
                var dir = Path.Combine(baseDir, "logs");
                Directory.CreateDirectory(dir);
                var probe = Path.Combine(dir, ".write-test");
                File.WriteAllText(probe, "ok");
                File.Delete(probe);
                return Path.Combine(dir, "douy.log");
            }
        }
        catch
        {
            // 继续尝试下一个位置
        }

        // 2) %APPDATA%\DOUY
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "DOUY");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "douy.log");
        }
        catch
        {
            // 继续
        }

        // 3) 临时目录
        return Path.Combine(Path.GetTempPath(), "douy.log");
    }

    private static void WriteToFile(string text)
    {
        try
        {
            lock (Gate)
            {
                var info = new FileInfo(LogFilePath);
                if (info.Exists && info.Length > 5 * 1024 * 1024)
                {
                    var backup = LogFilePath + ".1";
                    try
                    {
                        if (File.Exists(backup))
                        {
                            File.Delete(backup);
                        }

                        File.Move(LogFilePath, backup);
                    }
                    catch
                    {
                        // 轮转失败就继续追加
                    }
                }

                File.AppendAllText(LogFilePath, text + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch
        {
            // 磁盘只读 / 权限不足时静默
        }
    }
}
