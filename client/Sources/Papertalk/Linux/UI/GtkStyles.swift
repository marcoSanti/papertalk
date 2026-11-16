// App-wide GTK styling on Linux: hover and press feedback that SwiftCrossUI's fixed control
// colours would otherwise hide.

#if os(Linux)
import CGtk
import Foundation
import SwiftCrossUI

/// SwiftCrossUI gives every control a fixed background in its own stylesheet, which overrides
/// the theme's `:hover` and `:active` states, so buttons gave no feedback. One stylesheet at
/// GTK's user priority (above SwiftCrossUI's) restores them, with a short transition.
enum GtkStyles {
    /// Install the stylesheet for `scheme` on the default display (once the window exists).
    @MainActor
    static func install(_ scheme: ColorScheme) {
        guard !installed, let display = gdk_display_get_default() else { return }
        installed = true
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, css(for: scheme))
        gtk_style_context_add_provider_for_display(display, OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_USER))
    }

    @MainActor private static var installed = false

    /// The stylesheet: tints for hovered, pressed and disabled controls in this scheme.
    static func css(for scheme: ColorScheme) -> String {
        let (hover, press) = scheme == .dark
            ? ("rgba(255,255,255,0.18)", "rgba(255,255,255,0.30)")
            : ("rgba(0,0,0,0.12)", "rgba(0,0,0,0.22)")
        return """
        button { transition: background-color 120ms ease-out, opacity 120ms ease-out; }
        button:hover { background-color: \(hover); }
        button:active, button:checked { background-color: \(press); }
        button:disabled { opacity: 0.45; }
        scale trough highlight { transition: none; }
        """
    }
}
#endif
