import CoreGraphics

/// What a recording captures: the whole display under the cursor, or a fixed
/// region of one display — an area the user dragged out, or the frame a
/// window had when recording started. Region rects are global CoreGraphics
/// coordinates (origin top-left, y down), in points.
enum RecordingTarget: Equatable {
    case screen
    case region(CGRect)
}
