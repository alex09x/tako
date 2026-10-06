import Carbon

class KeyboardLayout {
    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return unsafeBitCast(sourceIdPointer, to: CFString.self) as String
    }
}
