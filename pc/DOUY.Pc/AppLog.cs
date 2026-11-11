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
            Console.WriteLine(text);
        }

        try
        {
            LineWritten?.Invoke(text);
        }
        catch
        {
            // 日志本身的异常一律吞掉
        }
    }
}
