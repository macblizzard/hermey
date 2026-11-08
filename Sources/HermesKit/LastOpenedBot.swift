/// Orders a host's directory without disturbing the relative order of other bots.
public enum LastOpenedBot {
    public static func order(_ bots: [Bot], lastOpenedID: String?) -> [Bot] {
        guard let lastOpenedID,
              let index = bots.firstIndex(where: { $0.id == lastOpenedID }) else { return bots }
        var result = bots
        let opened = result.remove(at: index)
        result.insert(opened, at: 0)
        return result
    }
}
