public enum TextFieldValidationError: Error, Equatable, Sendable {
    case containsControlCharacter(field: String)
    case invalidLength(field: String, utf8Bytes: Int)
}

public enum TextFieldValidator {
    public static func validate(_ value: String?, field: String) throws {
        guard let value else { return }
        guard (1...256).contains(value.utf8.count) else {
            throw TextFieldValidationError.invalidLength(
                field: field,
                utf8Bytes: value.utf8.count
            )
        }
        guard !value.unicodeScalars.contains(where: { scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
        }) else {
            throw TextFieldValidationError.containsControlCharacter(field: field)
        }
    }
}
