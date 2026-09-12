import Foundation

/// Task 4, шаг 3: DTO и точное вычитание баланса.
/// Decimal декодируется напрямую из JSON — без промежуточного Double.
public enum OpenRouterParser {
    private struct CreditsEnvelope: Decodable {
        struct Credits: Decodable {
            let total_credits: Decimal
            let total_usage: Decimal
        }
        let data: Credits
    }

    /// Баланс = total_credits − total_usage, точное десятичное вычитание.
    /// Отсутствующее поле, null, неверный тип или не-JSON → invalidData.
    public static func balance(from data: Data) throws -> Decimal {
        let value: CreditsEnvelope
        do {
            value = try JSONDecoder().decode(CreditsEnvelope.self, from: data)
        } catch {
            throw ProviderError.invalidData
        }
        var credits = value.data.total_credits
        var usage = value.data.total_usage
        var balance = Decimal()
        guard NSDecimalSubtract(&balance, &credits, &usage, .plain) == .noError,
              !balance.isNaN else { throw ProviderError.invalidData }
        return balance
    }
}
