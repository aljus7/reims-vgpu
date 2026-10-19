using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ReimsLauncher;

public partial class MainWindow
{
    private void RunSelfTest()
    {
        string[] args = Environment.GetCommandLineArgs();
        string directory = Path.GetFullPath(args[Array.IndexOf(args, "--self-test") + 1]);
        Directory.CreateDirectory(directory);
        _themeFile = Path.Combine(directory, "theme.json");
        try
        {
            int checks = 0;
            void Check(bool condition, string message)
            {
                if (!condition) throw new InvalidOperationException(message);
                checks++;
            }
            if (File.Exists(_themeFile)) File.Delete(_themeFile);
            LoadTheme();
            Check(DarkMode.IsChecked is null, "First launch must follow Windows theme.");
            var original = new VmRow("Default", 8, 1, "8 GiB", "128 GiB", "Stopped", false);
            var named = original with { Name = "Test", Threads = 2 };
            var running = named with { Running = true };
            VmList.ItemsSource = new[] { original, named, running };
            VmList.SelectedItem = original;
            UpdateButtons();
            Check(!DeleteButton.IsEnabled, "Default deletion must be disabled.");
            Check(ApplyCpuButton.IsEnabled, "Stopped VM CPU settings must be editable.");
            VmList.SelectedItem = named;
            UpdateButtons();
            Check(DeleteButton.IsEnabled, "Named stopped VM deletion must be available.");
            Check(SelectedThreads.SelectedIndex == 1 && named.Topology == "4 × 2", "Saved SMT must load correctly.");
            VmList.SelectedItem = running;
            UpdateButtons();
            Check(!DeleteButton.IsEnabled && !ApplyCpuButton.IsEnabled, "Running VM changes must be disabled.");
            _busy = true;
            VmList.SelectedItem = named;
            UpdateButtons();
            Check(!DeleteButton.IsEnabled && !ApplyCpuButton.IsEnabled, "Busy app must disable destructive controls.");
            _busy = false;
            VmList.SelectedItem = named;
            UpdateButtons();
            CoresSlider.Value = 3;
            ThreadsCombo.SelectedIndex = 1;
            Check(TopologyLabel.Text.Contains("even"), "Odd SMT must show an error.");
            CoresSlider.Value = 8;
            Check(TopologyLabel.Text.Contains("4 cores"), "Eight SMT vCPUs must display four cores.");
            foreach (bool dark in new[] { true, false })
            {
                DarkMode.IsChecked = dark;
                Check(System.Text.Json.JsonSerializer.Deserialize<bool?>(File.ReadAllText(_themeFile)) == dark, "Theme must persist.");
                LoadTheme();
                Check(DarkMode.IsChecked == dark, "Saved theme must survive reload.");
                UpdateLayout();
                Check((((SolidColorBrush)Background).Color.R < 128) == dark,
                    "Theme must update the window.");
                Color surface = ((SolidColorBrush)LogBox.Background).Color;
                Color backdrop = ((SolidColorBrush)Background).Color;
                double red = surface.R * (surface.A / 255.0) + backdrop.R * (1 - surface.A / 255.0);
                Check((red < 128) == dark,
                    "Theme must update input surfaces.");
                var bitmap = new RenderTargetBitmap((int)ActualWidth, (int)ActualHeight, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(this);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var output = File.Create(Path.Combine(directory, dark ? "dark.png" : "light.png"));
                encoder.Save(output);
            }
            DarkMode.IsChecked = null;
            LoadTheme();
            Check(DarkMode.IsChecked is null, "Windows theme preference must survive reload.");
            File.WriteAllText(Path.Combine(directory, "result.txt"), $"PASS: {checks} launcher UI assertions.");
            Application.Current.Shutdown(0);
        }
        catch (Exception error)
        {
            File.WriteAllText(Path.Combine(directory, "result.txt"), error.ToString());
            Application.Current.Shutdown(1);
        }
    }
}
