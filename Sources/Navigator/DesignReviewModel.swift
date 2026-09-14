import Foundation

struct DesignReview:Decodable {
    struct Finding:Decodable,Identifiable {
        let id,sentiment,title,detail,evidence:String
        let rank,impactPerEffort:Int
    }
    struct Recommendation:Decodable,Identifiable {
        let id,title,action,benefit,effort:String
    }
    let summary,limitations:String
    let findings:[Finding]
    let recommendations:[Recommendation]
    /// Present only when the response is valid JSON but has fewer interactive
    /// sections than the full design-review prompt requested.
    let warning:String?
    static func parse(_ text:String)->DesignReview? {
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines)
        let payload:String
        if trimmed.hasPrefix("```json"),trimmed.hasSuffix("```") {payload=String(trimmed.dropFirst(7).dropLast(3))}
        else {payload=trimmed}
        guard let data=payload.data(using:.utf8),
              let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return nil }
        let hasReviewField=["summary","limitations","findings","recommendations"].contains {object[$0] != nil}
        guard hasReviewField else { return nil }
        if let value=object["summary"], !(value is String) {return nil}
        if let value=object["limitations"], !(value is String) {return nil}
        let summary=object["summary"] as? String ?? "Partial design review"
        let limitations=object["limitations"] as? String ?? "Codex did not provide review scope or limitations."
        func array(_ key:String) -> [[String:Any]]? {
            guard let value=object[key] else {return []}
            return value as? [[String:Any]]
        }
        guard let findingsData=array("findings"), let recommendationData=array("recommendations") else {return nil}
        func finding(_ item:[String:Any])->Finding? {
            guard let id=item["id"] as? String, let sentiment=item["sentiment"] as? String,
                  let title=item["title"] as? String, let detail=item["detail"] as? String,
                  let evidence=item["evidence"] as? String, let rank=item["rank"] as? Int,
                  let impact=item["impactPerEffort"] as? Int,
                  ["Love","Like","Dislike","Hate"].contains(sentiment), rank > 0,
                  (1...5).contains(impact) else { return nil }
            return Finding(id:id,sentiment:sentiment,title:title,detail:detail,evidence:evidence,rank:rank,impactPerEffort:impact)
        }
        func recommendation(_ item:[String:Any])->Recommendation? {
            guard let id=item["id"] as? String, let title=item["title"] as? String,
                  let action=item["action"] as? String, let benefit=item["benefit"] as? String,
                  let effort=item["effort"] as? String else { return nil }
            return Recommendation(id:id,title:title,action:action,benefit:benefit,effort:effort)
        }
        let findings=findingsData.compactMap(finding)
        let recommendations=recommendationData.compactMap(recommendation)
        guard findings.count == findingsData.count, recommendations.count == recommendationData.count,
              Set(findings.map(\.id)).count == findings.count, Set(recommendations.map(\.id)).count == recommendations.count,
              Set(findings.map(\.rank)).count == findings.count else { return nil }
        let complete=findings.count == 10 && recommendations.count == 5 &&
            findings.filter({["Love","Like"].contains($0.sentiment)}).count == 5 &&
            findings.filter({["Dislike","Hate"].contains($0.sentiment)}).count == 5 &&
            Set(findings.map(\.rank)) == Set(1...10)
        let warning=complete ? nil : "This is a partial structured review. It is shown as received; ask Codex to complete it before relying on a full ranking."
        return DesignReview(summary:summary, limitations:limitations, findings:findings, recommendations:recommendations, warning:warning)
    }
    static let instructions="""
    Present this review in Navigator's interactive design review format. Return only a JSON object (no Markdown table or surrounding prose) with this shape:
    {"summary":"brief overall assessment","limitations":"what you inspected and could not evaluate","findings":[{"id":"f1","sentiment":"Love","title":"short finding","detail":"user impact and explanation","evidence":"Observed: concrete evidence, or Preference: subjective judgment","rank":1,"impactPerEffort":4}],"recommendations":[{"id":"r1","title":"short action title","action":"concrete next action","benefit":"expected user benefit","effort":"approximate effort"}]}
    Include exactly 10 unique findings: first 5 positives labelled Love or Like, then 5 negatives labelled Dislike or Hate. Use the intensity honestly. Rank all findings uniquely 1–10 by importance, while keeping positives first. Include exactly 5 prioritised recommendations with unique IDs. Impact per Effort is an estimate from 1 (low user value, substantial effort) to 5 (high user value, little effort); score strengths by opportunities to build on them. Be concise. Do not implement changes. The user will select recommendations and provide agreement ratings and optional explanations in Navigator.
    """
}

struct ReviewFeedback: Codable, Equatable {
    var ratings:[String:String]=[:]
    var notes:[String:String]=[:]
    var selected:Set<String>=[]
    var clarifications:[String:String]=[:]
    func prompt(for review:DesignReview)->String {
        var lines=["My feedback on your design review:"]
        for f in review.findings {
            let rating=ratings[f.id] ?? "",note=notes[f.id] ?? ""
            if !rating.isEmpty || !note.isEmpty {lines.append("- \(f.title): \(rating.isEmpty ? "No rating" : rating). \(note)")}
        }
        if selected.isEmpty {lines.append("Respond to my feedback only. Do not implement changes.")}
        else {
            lines.append("Implement only these selected recommendations, taking my feedback into account. Ask about unresolved design decisions before implementing affected changes:")
            for r in review.recommendations where selected.contains(r.id) {
                lines.append("- \(r.title): \(r.action)\n  My clarification: \(clarifications[r.id] ?? "None")")
            }
            lines.append("Unselected recommendations are not authorised.")
        }
        return lines.joined(separator:"\n")
    }
}
