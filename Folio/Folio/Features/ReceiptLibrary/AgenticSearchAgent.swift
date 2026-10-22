//
//  AgenticSearchAgent.swift
//  Folio
//
//  Created by Ziyan Nadeem on 21/10/2026.
//

import SwiftUI
import FoundationModels

struct DashboardInsight: Equatable {
    let periodName: String
    let totalSpending: Decimal
    let changePercentage: Decimal?
    let transactionCount: Int
    let averageTransaction: Decimal
    let topCategory: String
    let topCategoryAmount: Decimal
    let currencyCode: String
}

struct AgentMessage: Identifiable, Equatable {
    enum Sender { case user, assistant }

    let id = UUID()
    let sender: Sender
    let text: String
    let timestamp = Date.now
    var referencedReceipts: [ReceiptRecord] = []
    var followUpPrompts: [String] = []
    var dashboardInsight: DashboardInsight? = nil
}

// MARK: - Generable types

@Generable enum AgentIntent { case findReceipts, spending, returns, warranties, savings, other }
@Generable enum AgentTimeKind { case anytime, around, within, thisMonth, lastMonth, thisYear, lastYear }
@Generable enum AgentTimeUnit { case day, week, month, year }
@Generable enum AgentProfile { case any, personal, business }

@Generable
struct ReceiptQueryPlan {
    @Guide(description: "What the person wants. findReceipts: locate a purchase. spending: totals, trends, comparisons. returns: open return windows. warranties: warranty coverage. savings: ways to spend less. other: anything else.")
    var intent: AgentIntent
    @Guide(description: "Product, brand or store words to look for, lowercase, e.g. headphones or jb hi-fi. Leave empty when the question is not about a specific thing. Never include words like receipt, bought, warranty, spend.")
    var keywords: [String]
    @Guide(description: "A store name if one is clearly mentioned, otherwise an empty string.")
    var retailer: String
    @Guide(description: "A spending category such as Electronics or Groceries if clearly mentioned, otherwise an empty string.")
    var category: String
    @Guide(description: "personal or business only if the person says so, otherwise any.")
    var profile: AgentProfile
    @Guide(description: "anytime if no time is mentioned. around: roughly N units ago. within: during the last N units. Others are calendar periods.")
    var timeKind: AgentTimeKind
    @Guide(description: "N for around and within, otherwise 1.")
    var timeAmount: Int
    var timeUnit: AgentTimeUnit
    @Guide(description: "Minimum purchase total in whole currency units, 0 if not mentioned.")
    var minAmount: Int
    @Guide(description: "Maximum purchase total in whole currency units, 0 if not mentioned.")
    var maxAmount: Int
    @Guide(description: "true only when the question refers back to earlier results using words like those, that one, them, it.")
    var refersToPrevious: Bool
}

@Generable
struct AgentFollowUps {
    @Guide(description: "Two or three natural follow-up questions this person might ask next, each under eight words, specific to their receipts.")
    var followUps: [String]
}

@Generable
struct AgentSelection {
    @Guide(description: "Numbers of the purchases that clearly are, or include, what the person described. Empty if none clearly match.")
    var numbers: [Int]
}

// MARK: - Heuristic planner (offline fallback and cross-check)

enum HeuristicPlanner {
    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12
    ]
    private static let numPattern = "(\\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
    private static let unitPattern = "(day|week|wk|month|mo|year|yr)s?"

    static let stopwords: Set<String> = [
        "i", "me", "my", "mine", "we", "you", "your", "the", "a", "an", "of", "for", "to", "in", "on", "at", "by", "from",
        "with", "and", "or", "is", "are", "was", "were", "be", "do", "does", "did", "have", "has", "had", "how", "what",
        "which", "when", "where", "who", "show", "find", "get", "got", "buy", "bought", "purchase", "purchased",
        "purchases", "receipt", "receipts", "much", "many", "any", "all", "still", "can", "could", "should", "would",
        "please", "ago", "last", "this", "past", "previous", "month", "months", "year", "years", "week", "weeks", "day",
        "days", "yr", "yrs", "vs", "versus", "compare", "than", "over", "under", "above", "below", "spend", "spent",
        "spending", "total", "money", "save", "saving", "cut", "down", "cost", "costs", "warranty", "warranties",
        "return", "returns", "returned", "eligible", "active", "there", "that", "those", "these", "it", "them", "about",
        "tell", "give", "list", "recent", "latest", "new", "old", "item", "items", "thing", "things", "some", "personal",
        "business", "doing", "am", "im", "i'm", "ive", "i've", "need", "want", "like", "just", "also", "then", "so",
        "if", "not", "no", "yes", "mine", "out", "up", "more", "less", "than", "cheaper", "reduce", "budget", "expenses",
        "expense", "overview", "summary", "breakdown", "trend", "trends", "paid", "pay", "order", "ordered", "today",
        "yesterday", "now", "ever", "protection", "refund", "exchange", "ending", "expire", "expires", "expiring"
    ]

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func number(_ s: String) -> Int { Int(s) ?? numberWords[s] ?? 1 }

    private static func parseUnit(_ s: String) -> AgentTimeUnit {
        if s.hasPrefix("d") { return .day }
        if s.hasPrefix("w") { return .week }
        if s.hasPrefix("m") { return .month }
        return .year
    }

    static func plan(for query: String) -> ReceiptQueryPlan {
        let lower = query.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }

        var kind = AgentTimeKind.anytime
        var amount = 1
        var timeUnit = AgentTimeUnit.month
        if let m = capture("\(numPattern)\\s+\(unitPattern)\\s+ago", in: lower) {
            kind = .around; amount = number(m[0]); timeUnit = parseUnit(m[1])
        } else if let m = capture("(?:last|past|previous)\\s+\(numPattern)\\s+\(unitPattern)", in: lower) {
            kind = .within; amount = number(m[0]); timeUnit = parseUnit(m[1])
        } else if lower.contains("last month") {
            kind = .lastMonth
        } else if lower.contains("last year") {
            kind = .lastYear
        } else if lower.contains("this month") {
            kind = .thisMonth
        } else if lower.contains("this year") {
            kind = .thisYear
        } else if has(["last week", "this week", "past week"]) {
            kind = .within; timeUnit = .week
        } else if has(["past year", "past month"]) {
            kind = .within; timeUnit = lower.contains("past year") ? .year : .month
        } else if has(["yesterday", "today"]) {
            kind = .within; amount = 2; timeUnit = .day
        }

        var minAmount = 0
        var maxAmount = 0
        if let m = capture("(?:over|above|more than|at least)\\s*\\$?(\\d+)", in: lower) { minAmount = Int(m[0]) ?? 0 }
        if let m = capture("(?:under|below|less than|at most)\\s*\\$?(\\d+)", in: lower) { maxAmount = Int(m[0]) ?? 0 }

        let profile: AgentProfile = lower.contains("business") ? .business : (lower.contains("personal") ? .personal : .any)

        let tokens = lower.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        let keywords = tokens.filter { !stopwords.contains($0) && Int($0) == nil && $0.count > 1 }

        let intent: AgentIntent
        if has(["warrant", "applecare", "guarantee"]) { intent = .warranties }
        else if has(["return", "refund", "send back", "exchange"]) { intent = .returns }
        else if has(["save", "saving", "cut down", "reduce", "cheaper"]) { intent = .savings }
        else if has(["spend", "spent", "how much", "budget", "compare", "trend", "overview", "breakdown", "total", " vs "]) { intent = .spending }
        else if has(["find", "show", "where", "receipt", "bought", "got ", "purchase", "paid", "order"]) || !keywords.isEmpty { intent = .findReceipts }
        else { intent = .other }

        return ReceiptQueryPlan(
            intent: intent, keywords: Array(keywords.prefix(5)), retailer: "", category: "", profile: profile,
            timeKind: kind, timeAmount: amount, timeUnit: timeUnit, minAmount: minAmount, maxAmount: maxAmount,
            refersToPrevious: has(["those", "them", "that one", "the same", "which of"]))
    }
}

// MARK: - Deterministic query engine

struct AgentCoverage: Equatable {
    let title: String
    let kind: SavedPolicy.Kind
    let expiry: Date
    let daysLeft: Int
    var isActive: Bool { daysLeft >= 0 }
}

struct AgentDateWindow: Equatable {
    let start: Date
    let end: Date
    let label: String
    var center: Date { Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2) }
    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

struct AgentAnalysis {
    var matches: [ReceiptRecord]
    var referenced: [ReceiptRecord]
    var insight: DashboardInsight?
    var facts: String
    var fallbackText: String
    var followUps: [String]
}

struct ReceiptQueryEngine {
    struct Resolution {
        var matches: [ReceiptRecord]
        var unwindowed: [ReceiptRecord]
        var window: AgentDateWindow?
        var relaxedTime: Bool
        var terms: [String]
        var needsSemantic: Bool
        var candidates: [ReceiptRecord]
    }

    struct SpendSummary {
        var currency: String
        var total: Decimal
        var count: Int
        var average: Decimal
        var categories: [(name: String, amount: Decimal)]
        var stores: [(name: String, amount: Decimal, visits: Int)]
        var personal: Decimal
        var business: Decimal
        var largest: ReceiptRecord?
        var smallCount: Int
        var smallTotal: Decimal
    }

    let records: [ReceiptRecord]
    let now: Date
    private let calendar: Calendar

    init(records: [ReceiptRecord], now: Date = .now, calendar: Calendar = .current) {
        self.records = records
        self.now = now
        self.calendar = calendar
    }

    // MARK: Text matching

    private static let synonymGroups: [[String]] = [
        ["headphones", "earbuds", "earphones", "airpods", "headset", "buds"],
        ["laptop", "macbook", "notebook", "computer", "pc"],
        ["phone", "iphone", "mobile", "smartphone", "galaxy", "pixel"],
        ["tv", "television", "oled", "qled"],
        ["watch", "smartwatch"],
        ["fridge", "refrigerator"],
        ["coffee", "cafe", "espresso", "latte"],
        ["shoes", "sneakers", "trainers", "boots"],
        ["tablet", "ipad"],
        ["camera", "gopro", "lens"],
        ["speaker", "soundbar", "sonos"],
        ["groceries", "grocery", "supermarket", "woolworths", "coles", "aldi"],
        ["fuel", "petrol", "gas", "diesel"],
        ["furniture", "sofa", "couch", "desk", "chair", "table"]
    ]

    private static let genericWords: Set<String> = [
        "receipt", "receipts", "purchase", "purchases", "bought", "warranty", "warranties", "return", "returns",
        "spend", "spent", "item", "items", "thing", "things", "protection", "policy"
    ]

    private static func stem(_ text: String) -> String {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.count > 3, t.hasSuffix("s"), !t.hasSuffix("ss") { return String(t.dropLast()) }
        return t
    }

    private static let synonymLookup: [String: [String]] = {
        var map: [String: [String]] = [:]
        for group in synonymGroups {
            let stemmed = group.map(stem)
            for word in stemmed { map[word] = stemmed }
        }
        return map
    }()

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func hit(_ term: String, _ text: String, _ tokens: Set<String>) -> Bool {
        if term.count <= 3 { return tokens.contains(term) }
        return text.contains(term)
    }

    private func score(_ record: ReceiptRecord, terms: [String]) -> Int {
        let strong = ([record.receipt.retailer.name] + record.receipt.items.map(\.name)
                      + (record.costs?.products.map(\.name) ?? [])).joined(separator: " ").lowercased()
        let medium = record.metadata.category.lowercased()
        let weak = ([record.metadata.notes] + record.metadata.tags + record.metadata.policies.map(\.title))
            .joined(separator: " ").lowercased()
        let strongTokens = Self.tokens(strong), mediumTokens = Self.tokens(medium), weakTokens = Self.tokens(weak)

        var total = 0
        for term in terms {
            let stemmed = Self.stem(term)
            let group = Self.synonymLookup[stemmed] ?? [stemmed]
            var best = 0
            for t in group where !t.isEmpty {
                if Self.hit(t, strong, strongTokens) { best = max(best, 3) }
                else if Self.hit(t, medium, mediumTokens) { best = max(best, 2) }
                else if Self.hit(t, weak, weakTokens) { best = max(best, 1) }
            }
            total += best
        }
        return total
    }

    // MARK: Coverage

    func coverage(for record: ReceiptRecord) -> [AgentCoverage] {
        let start = calendar.startOfDay(for: now)
        func make(title: String, kind: SavedPolicy.Kind, days: Int) -> AgentCoverage? {
            guard let expiry = calendar.date(byAdding: .day, value: days, to: record.receipt.purchasedAt) else { return nil }
            let left = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: expiry)).day ?? 0
            return AgentCoverage(title: title, kind: kind, expiry: expiry, daysLeft: left)
        }
        var list = record.metadata.policies.compactMap { make(title: $0.title, kind: $0.kind, days: $0.windowDays) }
        if !list.contains(where: { $0.kind == .returns }), let legacy = record.receipt.returnPolicy,
           let item = make(title: "Return policy", kind: .returns, days: legacy.windowDays) {
            list.append(item)
        }
        return list
    }

    // MARK: Time windows

    private func component(_ unit: AgentTimeUnit) -> Calendar.Component {
        switch unit {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    private func unitName(_ unit: AgentTimeUnit, _ n: Int) -> String {
        let base: String
        switch unit {
        case .day: base = "day"
        case .week: base = "week"
        case .month: base = "month"
        case .year: base = "year"
        }
        return n == 1 ? base : base + "s"
    }

    private func interval(_ comp: Calendar.Component, offset: Int, label: String) -> AgentDateWindow? {
        guard let shifted = calendar.date(byAdding: comp, value: offset, to: now),
              let i = calendar.dateInterval(of: comp, for: shifted) else { return nil }
        return AgentDateWindow(start: i.start, end: i.end, label: label)
    }

    func window(for plan: ReceiptQueryPlan) -> AgentDateWindow? {
        let n = max(1, plan.timeAmount)
        let comp = component(plan.timeUnit)
        switch plan.timeKind {
        case .anytime:
            return nil
        case .around:
            guard let center = calendar.date(byAdding: comp, value: -n, to: now) else { return nil }
            let radius: Int
            switch plan.timeUnit {
            case .year: radius = 183
            case .month: radius = 15
            case .week: radius = 4
            case .day: radius = 2
            }
            guard let start = calendar.date(byAdding: .day, value: -radius, to: center),
                  let end = calendar.date(byAdding: .day, value: radius + 1, to: center) else { return nil }
            return AgentDateWindow(start: start, end: end, label: "about \(n) \(unitName(plan.timeUnit, n)) ago")
        case .within:
            guard let start = calendar.date(byAdding: comp, value: -n, to: now),
                  let end = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return AgentDateWindow(start: start, end: end, label: "the last \(n) \(unitName(plan.timeUnit, n))")
        case .thisMonth: return interval(.month, offset: 0, label: "this month")
        case .lastMonth: return interval(.month, offset: -1, label: "last month")
        case .thisYear: return interval(.year, offset: 0, label: "this year")
        case .lastYear: return interval(.year, offset: -1, label: "last year")
        }
    }

    private func periods(for plan: ReceiptQueryPlan) -> (current: AgentDateWindow, previous: AgentDateWindow)? {
        switch plan.timeKind {
        case .lastMonth:
            if let c = interval(.month, offset: -1, label: "last month"), let p = interval(.month, offset: -2, label: "the month before") { return (c, p) }
        case .thisYear:
            if let c = interval(.year, offset: 0, label: "this year"), let p = interval(.year, offset: -1, label: "last year") { return (c, p) }
        case .lastYear:
            if let c = interval(.year, offset: -1, label: "last year"), let p = interval(.year, offset: -2, label: "the year before") { return (c, p) }
        case .around, .within:
            if let w = window(for: plan) {
                let length = w.end.timeIntervalSince(w.start)
                let p = AgentDateWindow(start: w.start.addingTimeInterval(-length), end: w.start, label: "the period before")
                return (w, p)
            }
        default:
            break
        }
        if let c = interval(.month, offset: 0, label: "this month"), let p = interval(.month, offset: -1, label: "last month") { return (c, p) }
        return nil
    }

    // MARK: Resolution

    private func cleanedTerms(_ plan: ReceiptQueryPlan) -> [String] {
        var seen = Set<String>()
        return ([plan.retailer, plan.category] + plan.keywords)
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !Self.genericWords.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(6).map { $0 }
    }

    func resolve(_ plan: ReceiptQueryPlan, scope: [ReceiptRecord]) -> Resolution {
        var pool = scope
        if plan.profile != .any {
            let wanted: PurchaseProfile = plan.profile == .business ? .business : .personal
            pool = pool.filter { $0.receipt.profile == wanted }
        }
        if plan.minAmount > 0 { pool = pool.filter { $0.receipt.total >= Decimal(plan.minAmount) } }
        if plan.maxAmount > 0 { pool = pool.filter { $0.receipt.total <= Decimal(plan.maxAmount) } }

        let terms = cleanedTerms(plan)
        let timeWindow = window(for: plan)

        var scored: [(record: ReceiptRecord, score: Int)]
        if terms.isEmpty {
            scored = pool.map { (record: $0, score: 0) }
        } else {
            scored = pool.map { (record: $0, score: score($0, terms: terms)) }.filter { $0.score > 0 }
        }

        var matches = scored
        var relaxed = false
        if let timeWindow {
            let inside = scored.filter { timeWindow.contains($0.record.receipt.purchasedAt) }
            if inside.isEmpty && !scored.isEmpty { relaxed = true } else { matches = inside }
        }

        matches.sort { a, b in
            if let timeWindow {
                let da = abs(a.record.receipt.purchasedAt.timeIntervalSince(timeWindow.center))
                let db = abs(b.record.receipt.purchasedAt.timeIntervalSince(timeWindow.center))
                if a.score == b.score { return da < db }
            }
            if a.score != b.score { return a.score > b.score }
            return a.record.receipt.purchasedAt > b.record.receipt.purchasedAt
        }

        let needsSemantic = !terms.isEmpty && scored.isEmpty
        var candidates: [ReceiptRecord] = []
        if needsSemantic {
            var base = pool
            if let timeWindow {
                let inside = pool.filter { timeWindow.contains($0.receipt.purchasedAt) }
                if !inside.isEmpty { base = inside }
            }
            candidates = Array(base.sorted { $0.receipt.purchasedAt > $1.receipt.purchasedAt }.prefix(25))
        }

        return Resolution(matches: matches.map { $0.record }, unwindowed: scored.map { $0.record }, window: timeWindow,
                          relaxedTime: relaxed, terms: terms, needsSemantic: needsSemantic, candidates: candidates)
    }

    // MARK: Summaries

    private func primaryCurrency(of recs: [ReceiptRecord]) -> String {
        let counts = Dictionary(grouping: recs, by: { $0.receipt.currencyCode }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? "AUD"
    }

    private func summary(of recs: [ReceiptRecord], currency: String) -> SpendSummary {
        let rows = recs.filter { $0.receipt.currencyCode == currency }
        let total = rows.reduce(Decimal.zero) { $0 + $1.receipt.total }

        var categories: [String: Decimal] = [:]
        var stores: [String: (Decimal, Int)] = [:]
        for r in rows {
            let cat = r.metadata.category.trimmingCharacters(in: .whitespacesAndNewlines)
            categories[cat.isEmpty ? "Uncategorised" : cat, default: 0] += r.receipt.total
            let name = r.receipt.retailer.name
            let old = stores[name] ?? (0, 0)
            stores[name] = (old.0 + r.receipt.total, old.1 + 1)
        }
        let small = rows.filter { $0.receipt.total < 15 }

        return SpendSummary(
            currency: currency, total: total, count: rows.count,
            average: rows.isEmpty ? 0 : total / Decimal(rows.count),
            categories: categories.sorted { $0.value > $1.value }.map { (name: $0.key, amount: $0.value) },
            stores: stores.sorted { $0.value.0 > $1.value.0 }.map { (name: $0.key, amount: $0.value.0, visits: $0.value.1) },
            personal: rows.filter { $0.receipt.profile == .personal }.reduce(Decimal.zero) { $0 + $1.receipt.total },
            business: rows.filter { $0.receipt.profile == .business }.reduce(Decimal.zero) { $0 + $1.receipt.total },
            largest: rows.max { $0.receipt.total < $1.receipt.total },
            smallCount: small.count, smallTotal: small.reduce(Decimal.zero) { $0 + $1.receipt.total })
    }

    private func money(_ value: Decimal, _ code: String) -> String { value.formatted(.currency(code: code)) }
    private func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    private func percent(_ change: Decimal) -> String {
        String(format: "%+.1f%%", NSDecimalNumber(decimal: change).doubleValue)
    }

    private func describe(_ c: AgentCoverage) -> String {
        let kind = c.kind == .warranty ? "warranty" : "return window"
        if c.isActive { return "\(kind) \"\(c.title)\" ends \(day(c.expiry)) (\(c.daysLeft) days left)" }
        return "\(kind) \"\(c.title)\" ended \(day(c.expiry))"
    }

    private func line(_ record: ReceiptRecord, index: Int) -> String {
        let p = record.receipt
        var seen = Set<String>()
        let names = (p.items.map(\.name) + (record.costs?.products.map(\.name) ?? []))
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(4)
        var parts = ["\(index). \(p.retailer.name)", day(p.purchasedAt), money(p.total, p.currencyCode), p.profile.rawValue]
        if !record.metadata.category.isEmpty { parts.append(record.metadata.category) }
        if !names.isEmpty { parts.append("items: " + names.joined(separator: ", ")) }
        let cov = coverage(for: record)
        if !cov.isEmpty { parts.append("coverage: " + cov.map(describe).joined(separator: "; ")) }
        else { parts.append("no policies logged") }
        return parts.joined(separator: " | ")
    }

    // MARK: Analysis

    func analyse(_ plan: ReceiptQueryPlan, resolution: Resolution) -> AgentAnalysis {
        guard !records.isEmpty else {
            return AgentAnalysis(
                matches: [], referenced: [], insight: nil, facts: "No receipts are saved yet.",
                fallbackText: "Once you save a few receipts I can find purchases, track returns and warranties, and break down your spending.",
                followUps: [])
        }

        var matches = resolution.matches
        var expiredCount = 0
        if plan.intent == .returns || plan.intent == .warranties {
            let kind: SavedPolicy.Kind = plan.intent == .returns ? .returns : .warranty
            var rows: [(ReceiptRecord, Int)] = []
            for record in matches {
                let cov = coverage(for: record).filter { $0.kind == kind }
                guard !cov.isEmpty else { continue }
                if let soonest = cov.filter(\.isActive).map(\.daysLeft).min() { rows.append((record, soonest)) }
                else { expiredCount += 1 }
            }
            matches = rows.sorted { $0.1 < $1.1 }.map(\.0)
        }

        var lines: [String] = ["TODAY: \(day(now))", "QUESTION TYPE: \(plan.intent)"]
        if !resolution.terms.isEmpty { lines.append("SEARCH TERMS: " + resolution.terms.joined(separator: ", ")) }
        if let window = resolution.window {
            lines.append("TIME FILTER: \(window.label)" + (resolution.relaxedTime
                ? " (no matching purchases inside this window, so the closest matches are shown)" : ""))
        }

        let shown = Array(matches.prefix(6))
        switch plan.intent {
        case .findReceipts, .returns, .warranties, .other:
            if shown.isEmpty {
                lines.append("MATCHING RECEIPTS: none")
                if expiredCount > 0 { lines.append("\(expiredCount) matching receipts have only expired coverage") }
            } else {
                lines.append("MATCHING RECEIPTS (\(matches.count) total, showing \(shown.count)):")
                for (i, r) in shown.enumerated() { lines.append(line(r, index: i + 1)) }
                if expiredCount > 0 { lines.append("\(expiredCount) other receipts have only expired coverage") }
            }
            lines.append("NOTE: only policies logged on receipts are known. Do not guess unlogged warranties or return windows.")
        case .spending, .savings:
            break
        }

        let headsUp = records.flatMap { record in
            coverage(for: record).filter { $0.isActive && $0.daysLeft <= ($0.kind == .returns ? 7 : 30) }.map {
                (days: $0.daysLeft, text: "\(record.receipt.retailer.name) \($0.kind == .warranty ? "warranty" : "return window") ends in \($0.daysLeft) days (\(day($0.expiry)))")
            }
        }.sorted { $0.days < $1.days }.prefix(4)
        if !headsUp.isEmpty { lines.append("HEADS UP: " + headsUp.map { $0.text }.joined(separator: "; ")) }

        var insight: DashboardInsight?
        var spendText = ""
        var followUps: [String] = []

        if plan.intent == .spending || plan.intent == .savings {
            let pool = resolution.unwindowed
            let currency = primaryCurrency(of: pool)
            let periodPair = periods(for: plan)
            var current = pool
            var previous: [ReceiptRecord] = []
            var currentLabel = "overall"
            var previousLabel = ""
            if let pair = periodPair {
                let inCurrent = pool.filter { pair.current.contains($0.receipt.purchasedAt) }
                if !inCurrent.isEmpty || plan.timeKind != .anytime {
                    current = inCurrent
                    currentLabel = pair.current.label
                    previous = pool.filter { pair.previous.contains($0.receipt.purchasedAt) }
                    previousLabel = pair.previous.label
                }
            }

            let cur = summary(of: current, currency: currency)
            let prev = summary(of: previous, currency: currency)
            let all = summary(of: pool, currency: currency)
            let change: Decimal? = prev.total > 0 ? (cur.total - prev.total) / prev.total * 100 : nil
            let basis = cur.count > 0 ? cur : all
            let top = basis.categories.first

            lines.append("SPENDING \(currentLabel): \(money(cur.total, currency)) across \(cur.count) receipts, average \(money(cur.average, currency))")
            if !previousLabel.isEmpty {
                lines.append("SPENDING \(previousLabel): \(money(prev.total, currency)) across \(prev.count) receipts" + (change.map { ", change \(percent($0))" } ?? ""))
            }
            lines.append("ALL TIME (same filters): \(money(all.total, currency)) across \(all.count) receipts")
            let denominator = basis.total == 0 ? Decimal(1) : basis.total
            let cats = basis.categories.prefix(3).map {
                "\($0.name) \(money($0.amount, currency)) (\(String(format: "%.0f", NSDecimalNumber(decimal: $0.amount / denominator * 100).doubleValue))%)"
            }
            if !cats.isEmpty { lines.append("TOP CATEGORIES: " + cats.joined(separator: ", ")) }
            let stores = basis.stores.prefix(3).map { "\($0.name) \(money($0.amount, currency)) over \($0.visits) visits" }
            if !stores.isEmpty { lines.append("TOP STORES: " + stores.joined(separator: ", ")) }
            lines.append("PERSONAL \(money(basis.personal, currency)), BUSINESS \(money(basis.business, currency))")
            if plan.intent == .savings {
                if let big = basis.largest { lines.append("LARGEST PURCHASE: \(big.receipt.retailer.name) \(money(big.receipt.total, currency)) on \(day(big.receipt.purchasedAt))") }
                if basis.smallCount >= 3 { lines.append("SMALL PURCHASES under 15: \(basis.smallCount) totalling \(money(basis.smallTotal, currency))") }
                if let frequent = basis.stores.max(by: { $0.visits < $1.visits }), frequent.visits >= 3 {
                    lines.append("MOST FREQUENT STORE: \(frequent.name), \(frequent.visits) visits")
                }
            }
            if Set(pool.map { $0.receipt.currencyCode }).count > 1 {
                lines.append("NOTE: receipts in other currencies are excluded from totals.")
            }

            if cur.count > 0 || plan.timeKind != .anytime {
                insight = DashboardInsight(
                    periodName: currentLabel == "overall" ? "Overall" : currentLabel.prefix(1).uppercased() + currentLabel.dropFirst(),
                    totalSpending: cur.total, changePercentage: change, transactionCount: cur.count,
                    averageTransaction: cur.average, topCategory: top?.name ?? "General",
                    topCategoryAmount: top?.amount ?? 0, currencyCode: currency)
            }

            var text: String
            if cur.count == 0 {
                text = "I couldn't find any spending for \(currentLabel) in your saved receipts."
            } else {
                text = "You spent \(money(cur.total, currency)) \(currentLabel == "overall" ? "overall" : "in \(currentLabel)") across \(cur.count) receipt\(cur.count == 1 ? "" : "s")"
                if let change, !previousLabel.isEmpty {
                    text += ", \(change >= 0 ? "up" : "down") \(percent(abs(change)).replacingOccurrences(of: "+", with: "")) from \(previousLabel) (\(money(prev.total, currency)))"
                }
                text += "."
                if let top { text += " Your biggest category was \(top.name) at \(money(top.amount, currency))." }
                if plan.intent == .savings {
                    if basis.smallCount >= 3 { text += " \(basis.smallCount) small purchases added up to \(money(basis.smallTotal, currency)), which is the easiest place to trim." }
                    else if let frequent = basis.stores.max(by: { $0.visits < $1.visits }), frequent.visits >= 3 {
                        text += " You've shopped at \(frequent.name) \(frequent.visits) times, so a loyalty program or price comparison there could pay off."
                    } else if top != nil { text += " Comparing prices in that category is your best opportunity to save." }
                }
            }
            spendText = text
            followUps = plan.intent == .savings
                ? ["What is my personal vs business spend?", "Which store do I use most?", "Which returns are still open?"]
                : ["Where can I cut spending?", "What is my biggest purchase?", "Compare personal and business"]
        }

        let referenced: [ReceiptRecord]
        switch plan.intent {
        case .findReceipts, .returns, .warranties: referenced = Array(matches.prefix(4))
        case .spending, .savings:
            referenced = resolution.terms.isEmpty ? [] : Array(matches.prefix(3))
        case .other: referenced = []
        }

        var fallback = spendText
        if plan.intent == .returns || plan.intent == .warranties {
            let noun = plan.intent == .returns ? "return window" : "warranty"
            if let first = matches.first {
                let kind: SavedPolicy.Kind = plan.intent == .returns ? .returns : .warranty
                let next = coverage(for: first).filter { $0.kind == kind && $0.isActive }.min { $0.daysLeft < $1.daysLeft }
                fallback = "\(matches.count) purchase\(matches.count == 1 ? " has" : "s have") an active \(noun)."
                if let next {
                    fallback += " The next to end is \(first.receipt.retailer.name), on \(day(next.expiry)) (\(next.daysLeft) days left)."
                }
            } else {
                fallback = "I can't see any active \(noun)s in your saved receipts" + (expiredCount > 0 ? ", though \(expiredCount) have expired." : ".")
                    + " Policies only count once they are logged on a receipt."
            }
            followUps = plan.intent == .returns
                ? ["Which warranties are active?", "How much did I spend last month?"]
                : ["Which returns are still open?", "Anything ending soon?"]
        } else if plan.intent == .findReceipts || plan.intent == .other {
            if let first = matches.first {
                fallback = matches.count == 1
                    ? "I found one match: \(first.receipt.retailer.name) on \(day(first.receipt.purchasedAt)) for \(money(first.receipt.total, first.receipt.currencyCode))."
                    : "I found \(matches.count) matches. The best is \(first.receipt.retailer.name) on \(day(first.receipt.purchasedAt)) for \(money(first.receipt.total, first.receipt.currencyCode))."
                if resolution.relaxedTime { fallback += " Nothing was inside that time window, so these are the closest." }
                followUps = ["Is it still under warranty?", "Can I still return it?", "How much have I spent at \(first.receipt.retailer.name)?"]
            } else if resolution.terms.isEmpty {
                fallback = "I can look up purchases, check returns and warranties, or break down your spending. Try naming a store or item."
                followUps = []
            } else {
                fallback = "I couldn't find a receipt matching \(resolution.terms.joined(separator: ", ")). Try a store name or a different item word."
                followUps = ["Which returns are still open?", "How am I doing this month vs last month?"]
            }
        }

        return AgentAnalysis(matches: matches, referenced: referenced, insight: insight,
                             facts: lines.joined(separator: "\n"), fallbackText: fallback, followUps: followUps)
    }
}

// MARK: - View model

@MainActor @Observable
final class AgenticSearchViewModel {
    var messages: [AgentMessage] = []
    var currentInput: String = ""
    var isAnalyzing: Bool = false

    private let services: ReceiptLibraryServices
    private var allRecords: [ReceiptRecord] = []
    private let systemModel = SystemLanguageModel.default
    private var lastPlan: ReceiptQueryPlan?
    private var lastMatches: [ReceiptRecord] = []
    private var history: [(question: String, answer: String)] = []

    static let suggestedPrompts: [String] = [
        "Which returns are still open?",
        "Do I have any active warranties?",
        "How am I doing this month vs last month?",
        "Where can I cut my spending?"
    ]

    private static let plannerInstructions = """
    You convert a question about saved purchase receipts into a structured search plan. \
    Never answer the question. Fill only what the question states or clearly implies. \
    Use lowercase keywords for products, brands and stores. Leave fields empty or at their default when not mentioned.
    """

    private static let answerInstructions = """
    You are Folio, a sharp, warm assistant who knows the person's receipts inside out, like a friend who is great with money. \
    Talk naturally. Never sound like a form or a report. Vary how you open, and do not start with phrases like "I found", "Based on", or "You spent". \
    Lead with what matters most to them, then add one genuinely useful observation if the facts support it, such as a return window closing, \
    a warranty about to end, an unusual jump in spending, or a pattern worth noticing. Use HEADS UP facts only when they are relevant to the question. \
    Give an actual opinion or recommendation when they ask for advice, and be specific about stores, amounts and dates. \
    Match length to the question: a quick lookup gets a sentence or two, advice or analysis can take a short paragraph. \
    Use only the FACTS, which the app computed exactly, and never invent or recalculate figures. \
    If nothing matches, say so like a person would and suggest a smarter way to look. \
    Only logged policies are known, so never claim coverage that is not in the facts. No emojis, no markdown headings, never show IDs.
    """

    init(services: ReceiptLibraryServices) {
        self.services = services
        messages.append(AgentMessage(
            sender: .assistant,
            text: "Hi! Ask me to find a purchase, check returns and warranties, or break down your spending.",
            followUpPrompts: Self.suggestedPrompts))
    }

    private var modelAvailable: Bool { systemModel.availability == .available }

    func loadAndPrepareContext() async {
        await refreshRecords()
    }

    private func refreshRecords() async {
        let filter = ReceiptFilter(searchText: "", profile: nil, sort: .dateDescending)
        allRecords = (try? await services.searchReceipts(filter)) ?? allRecords
    }

    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnalyzing else { return }

        currentInput = ""
        messages.append(AgentMessage(sender: .user, text: trimmed))
        isAnalyzing = true

        Task {
            await refreshRecords()
            let reply = await generateReply(for: trimmed)
            messages.append(AgentMessage(
                sender: .assistant, text: reply.text, referencedReceipts: reply.referenced,
                followUpPrompts: reply.followUps, dashboardInsight: reply.insight))
            history.append((trimmed, reply.text))
            if history.count > 3 { history.removeFirst() }
            isAnalyzing = false
        }
    }

    private struct Reply {
        var text: String
        var referenced: [ReceiptRecord]
        var followUps: [String]
        var insight: DashboardInsight?
    }

    private func generateReply(for query: String) async -> Reply {
        let letters = query.filter(\.isLetter)
        guard letters.count >= 2 else {
            return Reply(text: "I can find purchases, check returns and warranties, or break down your spending. What would you like to know?",
                         referenced: [], followUps: Self.suggestedPrompts, insight: nil)
        }

        let plan = await makePlan(for: query)
        let scope = plan.refersToPrevious && !lastMatches.isEmpty ? lastMatches : allRecords
        let engine = ReceiptQueryEngine(records: allRecords)
        var resolution = engine.resolve(plan, scope: scope)

        if resolution.needsSemantic, modelAvailable, !resolution.candidates.isEmpty {
            let picks = await semanticMatches(query: query, terms: resolution.terms, candidates: resolution.candidates)
            if !picks.isEmpty {
                resolution.matches = picks
                resolution.unwindowed = picks
            }
        }

        let analysis = engine.analyse(plan, resolution: resolution)
        lastPlan = plan
        if !analysis.matches.isEmpty { lastMatches = Array(analysis.matches.prefix(10)) }

        let (text, followUps) = await narrate(query: query, analysis: analysis)
        return Reply(text: text, referenced: analysis.referenced,
                     followUps: followUps.isEmpty ? Self.suggestedPrompts : followUps, insight: analysis.insight)
    }

    // MARK: Model stages

    private func makePlan(for query: String) async -> ReceiptQueryPlan {
        let heuristic = HeuristicPlanner.plan(for: query)
        guard modelAvailable else { return heuristic }

        let categories = Set(allRecords.map(\.metadata.category).filter { !$0.isEmpty }).sorted().prefix(10)
        let stores = Dictionary(grouping: allRecords, by: { $0.receipt.retailer.name }).sorted { $0.value.count > $1.value.count }
            .prefix(10).map { $0.key }
        var prompt = "Today: \(Date.now.formatted(date: .long, time: .omitted))\n"
        prompt += "Known categories: \(categories.joined(separator: ", "))\n"
        prompt += "Known stores: \(stores.joined(separator: ", "))\n"
        if let last = history.last { prompt += "Previous question: \(last.question)\n" }
        prompt += "Question: \(query)"

        do {
            let session = LanguageModelSession(instructions: Self.plannerInstructions)
            var plan = try await session.respond(to: prompt, generating: ReceiptQueryPlan.self).content

            if heuristic.timeKind != .anytime {
                plan.timeKind = heuristic.timeKind
                plan.timeAmount = heuristic.timeAmount
                plan.timeUnit = heuristic.timeUnit
            }
            if heuristic.profile != .any { plan.profile = heuristic.profile }
            if heuristic.minAmount > 0 { plan.minAmount = heuristic.minAmount }
            if heuristic.maxAmount > 0 { plan.maxAmount = heuristic.maxAmount }
            if plan.intent == .other && heuristic.intent != .other { plan.intent = heuristic.intent }
            if plan.intent == .findReceipts && plan.keywords.isEmpty && plan.retailer.isEmpty && plan.category.isEmpty {
                plan.keywords = heuristic.keywords
            }
            if heuristic.refersToPrevious { plan.refersToPrevious = true }
            if plan.refersToPrevious, plan.keywords.isEmpty, let last = lastPlan {
                plan.keywords = last.keywords
            }
            return plan
        } catch {
            return heuristic
        }
    }

    private func semanticMatches(query: String, terms: [String], candidates: [ReceiptRecord]) async -> [ReceiptRecord] {
        let list = candidates.enumerated().map { index, record -> String in
            let r = record.receipt
            var seen = Set<String>()
            let names = (r.items.map(\.name) + (record.costs?.products.map(\.name) ?? []))
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(5).joined(separator: ", ")
            let category = record.metadata.category.isEmpty ? "" : " | \(record.metadata.category)"
            return "\(index + 1). \(r.retailer.name) | \(r.purchasedAt.formatted(date: .abbreviated, time: .omitted)) | \(names)\(category)"
        }.joined(separator: "\n")

        let prompt = """
        The person asked: "\(query)"
        They are looking for: \(terms.joined(separator: ", "))
        Which of these purchases are, or include, that? Product model names count (for example a model number for a known headphone product).
        \(list)
        """
        do {
            let session = LanguageModelSession(instructions: "You match purchases to a description. Only pick purchases that clearly match.")
            let picked = try await session.respond(to: prompt, generating: AgentSelection.self).content.numbers
            return picked.compactMap { $0 >= 1 && $0 <= candidates.count ? candidates[$0 - 1] : nil }
        } catch {
            return []
        }
    }

    private func narrate(query: String, analysis: AgentAnalysis) async -> (String, [String]) {
        let fallback = (sanitize(analysis.fallbackText), analysis.followUps)
        guard modelAvailable else { return fallback }

        let recent = history.suffix(2).map { "They asked: \($0.question.prefix(160))\nYou said: \($0.answer.prefix(240))" }.joined(separator: "\n")

        for limit in [3600, 1500] {
            var prompt = ""
            if !recent.isEmpty { prompt += "Earlier in this chat:\n\(recent)\n\n" }
            prompt += "They now ask: \(query)\n\nFACTS (exact, computed by the app):\n\(analysis.facts.prefix(limit))"
            do {
                let session = LanguageModelSession(instructions: Self.answerInstructions)
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.8))
                let answer = sanitize(response.content)
                guard !answer.isEmpty else { break }
                let followUps = await suggestFollowUps(query: query, answer: answer) ?? analysis.followUps
                return (answer, followUps)
            } catch {
                continue
            }
        }
        return fallback
    }

    private func suggestFollowUps(query: String, answer: String) async -> [String]? {
        do {
            let session = LanguageModelSession(instructions: "You suggest natural next questions a person might ask about their saved receipts.")
            let result = try await session.respond(to: "They asked: \(query)\nYou answered: \(answer)", generating: AgentFollowUps.self)
            let list = result.content.followUps.map(sanitize).filter { !$0.isEmpty }.prefix(3)
            return list.isEmpty ? nil : Array(list)
        } catch {
            return nil
        }
    }

    private func sanitize(_ text: String) -> String {
        var result = text
        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if let regex = try? NSRegularExpression(pattern: uuidPattern) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
        }
        result = String(result.unicodeScalars.filter { scalar in
            guard scalar.properties.isEmojiPresentation || scalar.properties.isEmoji else { return true }
            return (0x30...0x39).contains(scalar.value) || scalar.value == 0x23 || scalar.value == 0x2A
        })
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Views

private extension String {
    var markdown: AttributedString {
        (try? AttributedString(markdown: self, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(self)
    }
}

struct AgenticSearchSheetView: View {
    let services: ReceiptLibraryServices
    @State private var model: AgenticSearchViewModel
    @Environment(\.dismiss) private var dismiss

    init(services: ReceiptLibraryServices) {
        self.services = services
        _model = State(initialValue: AgenticSearchViewModel(services: services))
    }

    private var canSend: Bool {
        !model.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isAnalyzing
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(model.messages) { message in
                                ChatBubbleView(message: message, services: services)
                                    .id(message.id)
                            }

                            if model.isAnalyzing {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Searching your receipts…")
                                        .font(.footnote)
                                        .foregroundStyle(Color.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                .id("thinking")
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.messages) { _, _ in
                        if let lastID = model.messages.last?.id {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                    .onChange(of: model.isAnalyzing) { _, analyzing in
                        if analyzing { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                    }
                }

                VStack(spacing: 12) {
                    if let last = model.messages.last, !last.followUpPrompts.isEmpty, !model.isAnalyzing {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(last.followUpPrompts, id: \.self) { prompt in
                                    Button(prompt) { model.sendPrompt(prompt) }
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.BrandTeal.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Color.BrandTeal)
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("Ask about a purchase, returns, spending…", text: $model.currentInput)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .submitLabel(.send)
                            .onSubmit { model.sendPrompt(model.currentInput) }

                        Button {
                            model.sendPrompt(model.currentInput)
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(canSend ? Color.BrandTeal : Color.secondary)
                        }
                        .disabled(!canSend)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
            }
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.loadAndPrepareContext() }
        }
    }
}

struct ChatBubbleView: View {
    let message: AgentMessage
    let services: ReceiptLibraryServices

    var body: some View {
        VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 10) {
            HStack {
                if message.sender == .user { Spacer(minLength: 40) }

                Text(message.text.markdown)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        message.sender == .user ? Color.BrandTeal : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(message.sender == .user ? .white : .primary)

                if message.sender == .assistant { Spacer(minLength: 40) }
            }

            if let insight = message.dashboardInsight {
                DashboardInsightCard(insight: insight)
                    .padding(.top, 2)
            }

            if !message.referencedReceipts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Referenced Receipts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)

                    ForEach(message.referencedReceipts) { record in
                        NavigationLink(destination: ReceiptDetailView(record: record, services: services)) {
                            HStack {
                                Image(systemName: "receipt")
                                    .foregroundStyle(Color.BrandTeal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.receipt.retailer.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                    Text(record.receipt.purchasedAt, format: .dateTime.day().month().year())
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                Text(record.receipt.total.formatted(.currency(code: record.receipt.currencyCode)))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                            }
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct DashboardInsightCard: View {
    let insight: DashboardInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(insight.periodName + " Overview", systemImage: "chart.bar.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.BrandTeal)

                Spacer()

                if let change = insight.changePercentage {
                    let isUp = change > 0
                    let value = String(format: "%.1f%%", NSDecimalNumber(decimal: change).doubleValue)
                    Label("\(isUp ? "+" : "")\(value) vs previous", systemImage: isUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isUp ? Color.orange : Color.green)
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(insight.totalSpending.formatted(.currency(code: insight.currencyCode)))
                        .font(.headline.weight(.bold))
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Category")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(insight.topCategory)
                        .font(.headline.weight(.semibold))
                }

                Spacer()
            }
        }
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
