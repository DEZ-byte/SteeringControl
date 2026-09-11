using System.Text.Json;

namespace OpenSteer.Tests;

/// <summary>
/// Loads tools/golden_vectors.json, the cross-language conformance fixture that the
/// Python generator computes by execution. The same file is consumed by the Swift
/// XCTest target and by the ESP32 host-side test, so agreement here is agreement
/// across all four implementations.
/// </summary>
public static class Golden
{
    private static readonly Lazy<JsonDocument> Lazy = new(Load);

    public static JsonElement Root => Lazy.Value.RootElement;

    private static JsonDocument Load()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "golden_vectors.json");

        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                "golden_vectors.json is missing. Run: python tools/golden_vectors.py", path);
        }

        return JsonDocument.Parse(File.ReadAllText(path));
    }

    public static JsonElement Section(string name) => Root.GetProperty(name);

    public static byte[] Hex(string spaced) =>
        Convert.FromHexString(spaced.Replace(" ", string.Empty));

    public static uint HexU32(string prefixed) =>
        Convert.ToUInt32(prefixed.AsSpan(2).ToString(), 16);
}
