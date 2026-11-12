// Linux Foundation has no String(localized:); the checks only need the English text.
#if !canImport(Darwin)
extension String {
    init(localized value: String) { self = value }
}
#endif
