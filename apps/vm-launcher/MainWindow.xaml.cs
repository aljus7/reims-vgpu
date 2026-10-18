using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace ReimsLauncher;

internal sealed record VmRow(string Name, int Cpus, string Ram, string Disk, string State, bool Running);

public partial class MainWindow : Window
{
    private static readonly Regex NamePattern = new("^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$");
    private readonly string? _root;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(5) };
    private bool _busy;

    public MainWindow()
    {
        InitializeComponent();
        _root = FindRoot();
        int cores = Math.Clamp(Environment.ProcessorCount, 1, 64);
        CoresSlider.Maximum = cores;
        CoresSlider.Value = Math.Min(8, cores);
        UpdateLabels();
        if (_root is null)
        {
            Log("Could not find the reims-vgpu folder (scripts\\windows\\New-VM.ps1). Put the app inside the project or runtime folder.");
            CreateButton.IsEnabled = StartButton.IsEnabled = StopButton.IsEnabled = BrowseButton.IsEnabled = false;
            ImageStatus.Text = "Unavailable.";
            return;
        }
        Log($"Project folder: {_root}");
        UpdateImageStatus();
        _timer.Tick += async (_, _) => { if (!_busy) await RefreshAsync(); };
        _timer.Start();
        Loaded += async (_, _) => await RefreshAsync();
    }

    private static string? FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "New-VM.ps1")) || File.Exists(Path.Combine(dir.FullName, "scripts", "windows", "New-VM.ps1")))
                return dir.FullName;
        return null;
    }

    private string Script(string name)
    {
        string atRoot = Path.Combine(_root!, name);
        return File.Exists(atRoot) ? atRoot : Path.Combine(_root!, "scripts", "windows", name);
    }

    private void Log(string text) => Dispatcher.Invoke(() => { LogBox.AppendText(text + Environment.NewLine); LogBox.ScrollToEnd(); });

    private async Task<(int Code, string Output)> RunAsync(string script, params string[] args)
    {
        var info = new ProcessStartInfo("pwsh.exe")
        {
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8, UseShellExecute = false, CreateNoWindow = true,
            WorkingDirectory = _root!,
        };
        foreach (var a in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Script(script) }.Concat(args)) info.ArgumentList.Add(a);
        try
        {
            using var process = Process.Start(info)!;
            var output = new System.Text.StringBuilder();
            void Pump(StreamReader reader) { string? line; while ((line = reader.ReadLine()) is not null) { lock (output) output.AppendLine(line); } }
            await Task.WhenAll(Task.Run(() => Pump(process.StandardOutput)), Task.Run(() => Pump(process.StandardError)), process.WaitForExitAsync());
            return (process.ExitCode, output.ToString().Trim());
        }
        catch (Exception ex) { return (-1, "Could not run PowerShell 7 (pwsh.exe): " + ex.Message); }
    }

    private async Task RefreshAsync()
    {
        string? selected = (VmList.SelectedItem as VmRow)?.Name;
        var (code, output) = await RunAsync("Get-VMList.ps1");
        if (code != 0) { Log("Could not list VMs: " + output); return; }
        try
        {
            var rows = JsonSerializer.Deserialize<List<JsonElement>>(output)!.Select(e => new VmRow(
                e.GetProperty("name").GetString()!, e.GetProperty("cpus").GetInt32(),
                $"{e.GetProperty("memory_mib").GetInt32() / 1024.0:0.#} GiB", $"{e.GetProperty("disk_gib").GetInt32()} GiB",
                e.GetProperty("running").GetBoolean() ? "Running" : "Stopped", e.GetProperty("running").GetBoolean())).ToList();
            VmList.ItemsSource = rows;
            VmList.SelectedItem = rows.FirstOrDefault(r => r.Name == selected) ?? rows.FirstOrDefault();
        }
        catch (Exception ex) { Log("Unexpected VM list: " + ex.Message + " " + output); }
        UpdateButtons();
    }

    private void UpdateButtons()
    {
        var row = VmList.SelectedItem as VmRow;
        StartButton.IsEnabled = !_busy && row is { Running: false };
        StopButton.IsEnabled = !_busy && row is { Running: true };
        CreateButton.IsEnabled = !_busy && _root is not null && ImageReady;
        BrowseButton.IsEnabled = !_busy && _root is not null;
    }

    private string ImagePath => Path.Combine(_root ?? "", "vm", "media", "Tahoe-Recovery-GPT.img");
    private bool ImageReady => _root is not null && File.Exists(ImagePath);

    private void UpdateImageStatus()
    {
        ImageStatus.Text = ImageReady
            ? $"Ready ({new FileInfo(ImagePath).Length / 1048576} MiB). Browse to replace it."
            : "Missing. Browse to your GPT Recovery image (.img) before creating a VM.";
        ImageStatus.Foreground = ImageReady ? System.Windows.Media.Brushes.DarkGreen : System.Windows.Media.Brushes.Firebrick;
    }

    private async void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "Select macOS Recovery image", Filter = "Disk images (*.img;*.raw)|*.img;*.raw|All files (*.*)|*.*" };
        if (dialog.ShowDialog(this) != true) return;
        string source = dialog.FileName, target = ImagePath;
        if (string.Equals(Path.GetFullPath(source), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase)) { UpdateImageStatus(); return; }
        _busy = true; UpdateButtons();
        Log($"> Copying Recovery image to {target} ...");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            string temp = target + ".partial";
            await Task.Run(() => { File.Copy(source, temp, true); File.Move(temp, target, true); });
            Log("Recovery image copied. It is validated when you create a VM.");
        }
        catch (Exception ex) { Log("Could not copy the image: " + ex.Message); }
        _busy = false;
        UpdateImageStatus();
        UpdateButtons();
    }

    private void UpdateLabels()
    {
        if (CoresLabel is null || RamLabel is null) return;
        CoresLabel.Text = ((int)CoresSlider.Value).ToString();
        RamLabel.Text = ((int)RamSlider.Value).ToString();
    }

    private void Slider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e) => UpdateLabels();
    private void VmList_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateButtons();
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private async Task RunActionAsync(string title, string script, params string[] args)
    {
        _busy = true; UpdateButtons();
        Log($"> {title} ...");
        var (code, output) = await RunAsync(script, args);
        if (output.Length > 0) Log(output);
        Log(code == 0 ? $"{title}: done." : $"{title}: failed (exit code {code}).");
        _busy = false;
        await RefreshAsync();
    }

    private async void Create_Click(object sender, RoutedEventArgs e)
    {
        string name = NameBox.Text.Trim();
        if (!NamePattern.IsMatch(name)) { MessageBox.Show(this, "Name: 1 to 32 letters, digits, _ or -, starting with a letter or digit.", "Name"); return; }
        if (name.Equals("Default", StringComparison.OrdinalIgnoreCase) || (VmList.ItemsSource as IEnumerable<VmRow>)?.Any(r => r.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) == true)
        { MessageBox.Show(this, "A VM with that name already exists.", "Name"); return; }
        if (!int.TryParse(DiskBox.Text, out int disk) || disk is < 64 or > 2048) { MessageBox.Show(this, "Disk size must be 64 to 2048 GiB.", "Disk"); return; }
        int cpus = (int)CoresSlider.Value, ramMiB = (int)RamSlider.Value * 1024;
        await RunActionAsync($"Create '{name}' ({cpus} CPUs, {ramMiB / 1024} GiB RAM, {disk} GiB disk)", "New-VM.ps1",
            "-Name", name, "-DiskGiB", disk.ToString(), "-Cpus", cpus.ToString(), "-MemoryMiB", ramMiB.ToString());
        NameBox.Clear();
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        if (VmList.SelectedItem is not VmRow row) return;
        var args = new List<string> { "-VMName", row.Name };
        if (WithoutInstaller.IsChecked == true) args.Add("-WithoutInstaller");
        await RunActionAsync($"Start '{row.Name}'", "Start-VM.ps1", args.ToArray());
    }

    private async void Stop_Click(object sender, RoutedEventArgs e)
    {
        if (VmList.SelectedItem is not VmRow row) return;
        if (MessageBox.Show(this, $"Ask macOS in '{row.Name}' to shut down?", "Shut down", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
        await RunActionAsync($"Shut down '{row.Name}'", "Stop-VM.ps1", "-VMName", row.Name, "-Exit");
    }
}
