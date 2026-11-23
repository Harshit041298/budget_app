import Foundation

/// Turns noisy statement descriptors like
/// `POINT OF SALE PURCHASE TIM HORTONS #2345 TORONTO ON` into `Tim Hortons`.
public enum MerchantNormalizer {
    struct Known {
        let patterns: [String]
        let name: String
        let category: SpendCategory
    }

    /// Common Canadian merchants. Order matters: more specific first.
    static let known: [Known] = [
        Known(patterns: ["PAYMENT THANK YOU", "PAIEMENT MERCI", "PAYMENT - THANK YOU"], name: "Card Payment", category: .transfer),
        Known(patterns: ["UBER EATS", "UBER *EATS", "UBEREATS"], name: "Uber Eats", category: .dining),
        Known(patterns: ["DOORDASH"], name: "DoorDash", category: .dining),
        Known(patterns: ["SKIPTHEDISHES", "SKIP THE DISHES"], name: "SkipTheDishes", category: .dining),
        Known(patterns: ["AMAZON PRIME", "PRIME VIDEO", "AMAZON DIGITAL"], name: "Amazon Prime", category: .subscriptions),
        Known(patterns: ["AMZN", "AMAZON"], name: "Amazon", category: .shopping),
        Known(patterns: ["TIM HORTONS", "TIMHORTONS"], name: "Tim Hortons", category: .dining),
        Known(patterns: ["STARBUCKS"], name: "Starbucks", category: .dining),
        Known(patterns: ["MCDONALD"], name: "McDonald's", category: .dining),
        Known(patterns: ["A&W", "A & W"], name: "A&W", category: .dining),
        Known(patterns: ["SUBWAY"], name: "Subway", category: .dining),
        Known(patterns: ["SECOND CUP"], name: "Second Cup", category: .dining),
        Known(patterns: ["UBER", "LYFT"], name: "Uber", category: .transportation),
        Known(patterns: ["PRESTO"], name: "PRESTO", category: .transportation),
        Known(patterns: ["TTC "], name: "TTC", category: .transportation),
        Known(patterns: ["GO TRANSIT", "METROLINX"], name: "GO Transit", category: .transportation),
        Known(patterns: ["COMPASS", "TRANSLINK"], name: "TransLink", category: .transportation),
        Known(patterns: ["STM "], name: "STM", category: .transportation),
        Known(patterns: ["GREEN P", "IMPARK", "INDIGO PARK", "HONK", "PARKING"], name: "Parking", category: .transportation),
        Known(patterns: ["407 ETR"], name: "407 ETR", category: .transportation),
        Known(patterns: ["PETRO-CANADA", "PETRO CANADA", "PETROCAN"], name: "Petro-Canada", category: .fuel),
        Known(patterns: ["ESSO"], name: "Esso", category: .fuel),
        Known(patterns: ["SHELL"], name: "Shell", category: .fuel),
        Known(patterns: ["ULTRAMAR"], name: "Ultramar", category: .fuel),
        Known(patterns: ["PIONEER"], name: "Pioneer", category: .fuel),
        Known(patterns: ["HUSKY"], name: "Husky", category: .fuel),
        Known(patterns: ["CANADIAN TIRE GAS", "CT GAS"], name: "Canadian Tire Gas", category: .fuel),
        Known(patterns: ["COSTCO GAS"], name: "Costco Gas", category: .fuel),
        Known(patterns: ["COSTCO"], name: "Costco", category: .groceries),
        Known(patterns: ["LOBLAW"], name: "Loblaws", category: .groceries),
        Known(patterns: ["NO FRILLS", "NOFRILLS"], name: "No Frills", category: .groceries),
        Known(patterns: ["REAL CANADIAN SUPERSTORE", "RCSS", "SUPERSTORE"], name: "Real Canadian Superstore", category: .groceries),
        Known(patterns: ["SOBEYS"], name: "Sobeys", category: .groceries),
        Known(patterns: ["FRESHCO"], name: "FreshCo", category: .groceries),
        Known(patterns: ["METRO "], name: "Metro", category: .groceries),
        Known(patterns: ["FOOD BASICS"], name: "Food Basics", category: .groceries),
        Known(patterns: ["FORTINOS"], name: "Fortinos", category: .groceries),
        Known(patterns: ["ZEHRS"], name: "Zehrs", category: .groceries),
        Known(patterns: ["FARM BOY"], name: "Farm Boy", category: .groceries),
        Known(patterns: ["T&T", "T & T"], name: "T&T Supermarket", category: .groceries),
        Known(patterns: ["SAFEWAY"], name: "Safeway", category: .groceries),
        Known(patterns: ["SAVE ON FOODS", "SAVE-ON-FOODS"], name: "Save-On-Foods", category: .groceries),
        Known(patterns: ["IGA"], name: "IGA", category: .groceries),
        Known(patterns: ["MAXI"], name: "Maxi", category: .groceries),
        Known(patterns: ["PROVIGO"], name: "Provigo", category: .groceries),
        Known(patterns: ["WHOLE FOODS"], name: "Whole Foods", category: .groceries),
        Known(patterns: ["INSTACART"], name: "Instacart", category: .groceries),
        Known(patterns: ["WAL-MART", "WALMART", "WAL MART"], name: "Walmart", category: .shopping),
        Known(patterns: ["SHOPPERS DRUG", "SHOPPERS DRUG MART"], name: "Shoppers Drug Mart", category: .health),
        Known(patterns: ["REXALL"], name: "Rexall", category: .health),
        Known(patterns: ["LONDON DRUGS"], name: "London Drugs", category: .health),
        Known(patterns: ["JEAN COUTU", "PHARMAPRIX"], name: "Pharmacy", category: .health),
        Known(patterns: ["CANADIAN TIRE"], name: "Canadian Tire", category: .shopping),
        Known(patterns: ["BEST BUY"], name: "Best Buy", category: .shopping),
        Known(patterns: ["IKEA"], name: "IKEA", category: .shopping),
        Known(patterns: ["HOME DEPOT"], name: "Home Depot", category: .shopping),
        Known(patterns: ["DOLLARAMA"], name: "Dollarama", category: .shopping),
        Known(patterns: ["WINNERS", "HOMESENSE", "MARSHALLS"], name: "Winners", category: .shopping),
        Known(patterns: ["HUDSON'S BAY", "HUDSONS BAY", "THE BAY"], name: "Hudson's Bay", category: .shopping),
        Known(patterns: ["SPORT CHEK", "SPORTCHEK"], name: "Sport Chek", category: .shopping),
        Known(patterns: ["INDIGO", "CHAPTERS"], name: "Indigo", category: .shopping),
        Known(patterns: ["APPLE.COM/BILL", "APPLE.COM BILL", "ITUNES"], name: "Apple Services", category: .subscriptions),
        Known(patterns: ["APPLE STORE", "APPLE.COM"], name: "Apple", category: .shopping),
        Known(patterns: ["NETFLIX"], name: "Netflix", category: .subscriptions),
        Known(patterns: ["SPOTIFY"], name: "Spotify", category: .subscriptions),
        Known(patterns: ["DISNEY PLUS", "DISNEYPLUS", "DISNEY+"], name: "Disney+", category: .subscriptions),
        Known(patterns: ["CRAVE"], name: "Crave", category: .subscriptions),
        Known(patterns: ["YOUTUBE", "GOOGLE *YOUTUBE"], name: "YouTube Premium", category: .subscriptions),
        Known(patterns: ["GOOGLE *", "GOOGLE STORAGE", "GOOGLE ONE"], name: "Google", category: .subscriptions),
        Known(patterns: ["MICROSOFT", "XBOX"], name: "Microsoft", category: .subscriptions),
        Known(patterns: ["ADOBE"], name: "Adobe", category: .subscriptions),
        Known(patterns: ["OPENAI", "CHATGPT", "ANTHROPIC", "CLAUDE.AI"], name: "AI Subscription", category: .subscriptions),
        Known(patterns: ["AUDIBLE"], name: "Audible", category: .subscriptions),
        Known(patterns: ["PATREON"], name: "Patreon", category: .subscriptions),
        Known(patterns: ["GOODLIFE", "PLANET FITNESS", "FIT4LESS", "ANYTIME FITNESS"], name: "Gym", category: .personalCare),
        Known(patterns: ["ROGERS"], name: "Rogers", category: .phoneInternet),
        Known(patterns: ["BELL CANADA", "BELL MOBILITY", "BELL MTS", "BELL "], name: "Bell", category: .phoneInternet),
        Known(patterns: ["TELUS"], name: "Telus", category: .phoneInternet),
        Known(patterns: ["FIDO"], name: "Fido", category: .phoneInternet),
        Known(patterns: ["KOODO"], name: "Koodo", category: .phoneInternet),
        Known(patterns: ["VIRGIN PLUS", "VIRGIN MOBILE"], name: "Virgin Plus", category: .phoneInternet),
        Known(patterns: ["FREEDOM MOBILE"], name: "Freedom Mobile", category: .phoneInternet),
        Known(patterns: ["PUBLIC MOBILE"], name: "Public Mobile", category: .phoneInternet),
        Known(patterns: ["CHATR"], name: "Chatr", category: .phoneInternet),
        Known(patterns: ["SHAW", "VIDEOTRON", "COGECO", "TEKSAVVY", "START.CA"], name: "Internet Provider", category: .phoneInternet),
        Known(patterns: ["HYDRO ONE", "TORONTO HYDRO", "BC HYDRO", "HYDRO QUEBEC", "HYDRO-QUEBEC", "HYDRO OTTAWA", "ALECTRA", "ENMAX", "EPCOR"], name: "Electricity", category: .utilities),
        Known(patterns: ["ENBRIDGE", "FORTISBC", "ATCO", "NATURAL GAS"], name: "Natural Gas", category: .utilities),
        Known(patterns: ["CITY OF", "WATER BILL", "UTILITIES"], name: "Utilities", category: .utilities),
        Known(patterns: ["INTACT", "TD INSURANCE", "AVIVA", "BELAIR", "SONNET", "DESJARDINS INS", "COOPERATORS", "CO-OPERATORS", "MANULIFE", "SUN LIFE", "INSURANCE"], name: "Insurance", category: .insurance),
        Known(patterns: ["AIR CANADA", "WESTJET", "PORTER AIR", "FLAIR", "SWOOP"], name: "Airline", category: .travel),
        Known(patterns: ["AIRBNB"], name: "Airbnb", category: .travel),
        Known(patterns: ["EXPEDIA", "BOOKING.COM", "HOTELS.COM"], name: "Travel Booking", category: .travel),
        Known(patterns: ["MARRIOTT", "HILTON", "HYATT", "HOLIDAY INN", "BEST WESTERN"], name: "Hotel", category: .travel),
        Known(patterns: ["VIA RAIL"], name: "VIA Rail", category: .travel),
        Known(patterns: ["CINEPLEX", "LANDMARK CINEMAS"], name: "Cineplex", category: .entertainment),
        Known(patterns: ["TICKETMASTER", "STUBHUB"], name: "Tickets", category: .entertainment),
        Known(patterns: ["STEAM", "PLAYSTATION", "NINTENDO", "EPIC GAMES"], name: "Games", category: .entertainment),
        Known(patterns: ["LCBO", "BEER STORE", "SAQ", "BC LIQUOR"], name: "Liquor Store", category: .dining),
        Known(patterns: ["ANNUAL FEE", "SERVICE CHARGE", "MONTHLY FEE", "OVERDRAFT", "INTEREST CHARGE", "PURCHASE INTEREST", "NSF FEE", "FOREIGN TRANSACTION FEE", "ACCOUNT FEE"], name: "Bank Fee", category: .fees),
        Known(patterns: ["PAYROLL", "PAY DEPOSIT", "DIRECT DEP", "SALARY"], name: "Payroll", category: .income),
        Known(patterns: ["CANADA RIT", "GST CREDIT", "CRA ", "CANADA FED", "CCB "], name: "Government Deposit", category: .income),
        Known(patterns: ["CIBC VISA", "CIBC MC", "CIBC MASTERCARD", "PAYMENT CIBC", "CREDIT CARD PAYMENT", "BILL PAYMENT"], name: "Credit Card Payment", category: .transfer),
        Known(patterns: ["INTERNET TRANSFER", "TRANSFER TO", "TRANSFER FROM", "ONLINE TRANSFER"], name: "Transfer", category: .transfer),
        Known(patterns: ["E-TRANSFER", "INTERAC E-TRF", "E-TFR", "ETRANSFER"], name: "Interac e-Transfer", category: .transfer),
        Known(patterns: ["RENT", "PROPERTY MGMT", "PROPERTY MANAGEMENT", "MORTGAGE"], name: "Rent / Mortgage", category: .housing),
        Known(patterns: ["CANADAHELPS", "UNITED WAY", "RED CROSS", "DONATION"], name: "Donation", category: .giftsDonations)
    ]

    /// Noise prefixes CIBC (and other banks) put in front of the merchant.
    static let prefixes = [
        "POINT OF SALE PURCHASE", "POINT OF SALE", "RETAIL PURCHASE", "VISA DEBIT PURCHASE",
        "VISA DEBIT RETAIL PURCHASE", "VISA DEBIT", "DEBIT PURCHASE", "PREAUTHORIZED DEBIT",
        "PRE-AUTHORIZED DEBIT", "PRE AUTHORIZED DEBIT", "ELECTRONIC FUNDS TRANSFER", "INTERNET BILL PAY",
        "BILL PAYMENT", "PURCHASE", "SQ *", "SQ*", "TST-", "TST*", "PAYPAL *", "PP*", "SP *", "SP*",
        "IC*", "FS *", "DD/", "CKE*", "ZTL*"
    ]

    static let provinces: Set<String> = ["ON", "QC", "BC", "AB", "MB", "SK", "NS", "NB", "NL", "PE", "YT", "NT", "NU",
                                         "CA", "CAN", "US", "USA", "WA", "NY", "CA.", "ONT"]

    /// Returns a known brand match for a raw descriptor, if any.
    public static func knownMatch(_ raw: String) -> (name: String, category: SpendCategory)? {
        let upper = " " + raw.uppercased() + " "
        for k in known {
            for p in k.patterns where upper.containsKeyword(p) {
                return (k.name, k.category)
            }
        }
        return nil
    }

    /// Cleans up a raw statement descriptor into a human-friendly merchant name.
    public static func normalize(_ raw: String) -> String {
        if let k = knownMatch(raw) { return k.name }

        var s = raw.uppercased().collapsingWhitespace
        var stripped = true
        while stripped {
            stripped = false
            for p in prefixes where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmed
                stripped = true
            }
        }
        // Drop reference numbers, store numbers and "*ABC123" suffixes.
        s = s.replacingOccurrences(of: #"\*\S*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"#\s?\d+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{3,}\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b[A-Z]*\d+[A-Z\d]*\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^A-Z&'\.\- ]"#, with: " ", options: .regularExpression)

        var words = s.split(separator: " ").map(String.init).filter { !$0.isEmpty && $0 != "-" }
        // Remove trailing province / country codes and a likely city name.
        if let last = words.last, provinces.contains(last) {
            words.removeLast()
            if words.count > 2 { words.removeLast() }   // city
        }
        if words.count > 4 { words = Array(words.prefix(4)) }
        let name = words.joined(separator: " ")
        guard !name.isEmpty else { return raw.trimmed.isEmpty ? "Unknown" : raw.trimmed }
        return name.split(separator: " ").map { w in
            w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Stable key used for remembering a user's category choice per merchant.
    public static func key(for merchant: String) -> String {
        merchant.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Fast, deterministic rule-based categoriser (first stage of the pipeline).
public enum RuleCategorizer {
    static let keywordRules: [(keywords: [String], category: SpendCategory)] = [
        (["GROCER", "SUPERMARKET", "MARKET", "FOODS", "BAKERY", "BUTCHER", "FRUIT"], .groceries),
        (["RESTAURANT", "CAFE", "COFFEE", "PIZZA", "SUSHI", "BURGER", "GRILL", "BISTRO", "PUB", "BAR ", "TAVERN", "KITCHEN", "THAI", "SHAWARMA", "PHO", "DINER", "EATS", "BBQ", "TACO"], .dining),
        (["GAS", "FUEL", "PETRO"], .fuel),
        (["TRANSIT", "TAXI", "CAB ", "PARKING", "PARK "], .transportation),
        (["PHARMACY", "DRUG", "CLINIC", "DENTAL", "DENTIST", "MEDICAL", "HEALTH", "OPTOM", "PHYSIO", "CHIRO", "HOSPITAL"], .health),
        (["SALON", "BARBER", "SPA ", "NAILS", "FITNESS", "GYM", "YOGA"], .personalCare),
        (["HOTEL", "INN ", "MOTEL", "AIRLINE", "AIRPORT", "RESORT"], .travel),
        (["UNIVERSITY", "COLLEGE", "SCHOOL", "TUITION", "COURSERA", "UDEMY"], .education),
        (["SUBSCRIPTION", "MEMBERSHIP", "PREMIUM"], .subscriptions),
        (["HYDRO", "ELECTRIC", "WATER", "UTILIT"], .utilities),
        (["WIRELESS", "MOBILE", "MOBILITY", "TELECOM", "INTERNET"], .phoneInternet),
        (["INSUR"], .insurance),
        (["CINEMA", "THEATRE", "THEATER", "MUSEUM", "TICKET", "BOWLING", "GOLF"], .entertainment),
        (["FEE", "INTEREST", "SERVICE CHARGE"], .fees),
        (["DEPOSIT", "PAYROLL", "REFUND"], .income),
        (["STORE", "SHOP", "MART", "OUTLET", "BOUTIQUE", "CLOTHING", "ELECTRONICS"], .shopping)
    ]

    /// Maps CIBC's own "Spend Categories" labels to ours.
    public static func fromCIBCLabel(_ label: String) -> SpendCategory? {
        let l = label.lowercased()
        if l.contains("restaurant") { return .dining }
        if l.contains("transportation") { return .transportation }
        if l.contains("retail and grocery") { return nil } // too broad; decide per merchant
        if l.contains("hotel") || l.contains("entertainment") { return .entertainment }
        if l.contains("health and education") { return .health }
        if l.contains("home and office") { return .shopping }
        if l.contains("personal and household") { return .personalCare }
        if l.contains("professional and financial") { return .fees }
        return nil
    }

    public static func categorize(rawDescription: String) -> SpendCategory? {
        if let k = MerchantNormalizer.knownMatch(rawDescription) { return k.category }
        let upper = " " + rawDescription.uppercased() + " "
        for rule in keywordRules where rule.keywords.contains(where: { upper.containsKeyword($0) }) {
            return rule.category
        }
        return nil
    }
}

extension String {
    /// Substring search that, for short keywords (<= 5 chars), requires the
    /// match not to be glued to other letters, so "ESSO" doesn't match
    /// "ESPRESSO" and "PUB" doesn't match "PUBLIC".
    func containsKeyword(_ keyword: String) -> Bool {
        let core = keyword.trimmingCharacters(in: .whitespaces)
        guard core.count <= 5 else { return contains(keyword) }
        var searchRange = startIndex..<endIndex
        while let r = range(of: core, range: searchRange) {
            let beforeOK = r.lowerBound == startIndex || !self[index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == endIndex || !self[r.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchRange = index(after: r.lowerBound)..<endIndex
        }
        return false
    }
}
