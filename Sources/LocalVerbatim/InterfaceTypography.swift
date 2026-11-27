import SwiftUI

private struct InterfaceFontScale: EnvironmentKey {
    static let defaultValue: Double = 1
}

private extension EnvironmentValues {
    var interfaceFontScale: Double {
        get { self[InterfaceFontScale.self] }
        set { self[InterfaceFontScale.self] = newValue }
    }
}

private struct InterfaceFont: ViewModifier {
    @Environment(\.interfaceFontScale) private var scale
    let size: Double
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    func interfaceTypography(_ size: InterfaceTextSize) -> some View {
        font(.system(size: 13 * size.scale)).environment(\.interfaceFontScale, size.scale)
    }

    func uiFont(_ size: Double, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(InterfaceFont(size: size, weight: weight, design: design))
    }
}
