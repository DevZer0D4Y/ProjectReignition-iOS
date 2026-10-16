using Godot;

namespace Project.Interface.Menus;

[Tool]
public partial class VideoStreamFileLoadPlayer : VideoStreamPlayer
{
	[Export(PropertyHint.File)]
	private string videoFilePath;
	public void SetVideoFilePath(string path) => videoFilePath = path;

	public override void _Ready()
	{
		if (Engine.IsEditorHint())
			return;

		ReloadVideoPath();
	}

	public void ReloadVideoPath()
	{
		if (string.IsNullOrEmpty(videoFilePath))
			return;

		string path = videoFilePath;
		if (!ResourceLoader.Exists(path, "VideoStream"))
		{
			// Platforms without the FFmpeg extension (iOS) play Ogg Theora copies
			// of the videos, which Godot decodes itself.
			string theoraPath = System.IO.Path.ChangeExtension(path, ".ogv");
			if (!ResourceLoader.Exists(theoraPath, "VideoStream"))
			{
				GD.PushWarning($"Couldn't load video file {videoFilePath}!");
				return;
			}
			path = theoraPath;
		}

		Stream = ResourceLoader.Load<VideoStream>(path, "VideoStream");
	}
}
