using System;
using System.IO;
using Windows.Storage.Streams;

// Small helper for the SMTC thumbnail stream. Windows PowerShell cannot call
// methods on the WinRT stream object it receives, so this reads it via .NET.
// Build with the Windows SDK union metadata (see README) or ship the included DLL.
public sealed class Artwork
{
    public string ContentType;
    public byte[] Data;
}

public static class MetrolistArtwork
{
    public static Artwork Read(object reference)
    {
        var source = (IRandomAccessStreamReference)reference;
        var task = source.OpenReadAsync().AsTask();
        if (!task.Wait(5000)) throw new TimeoutException("Artwork stream timed out.");
        using (var stream = task.Result)
        {
            var art = new Artwork { ContentType = stream.ContentType };
            using (var net = stream.AsStreamForRead())
            using (var buffer = new MemoryStream())
            {
                net.CopyTo(buffer);
                art.Data = buffer.ToArray();
            }
            return art;
        }
    }
}
