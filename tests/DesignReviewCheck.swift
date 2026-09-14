import Foundation

@main
struct DesignReviewCheck {
    static func main() throws {
        let text=try String(contentsOfFile:"tests/design_review_fixture.json")
        let review=DesignReview.parse(text)!
        precondition(DesignReview.parse("```json\n"+text+"\n```") != nil)
        precondition(DesignReview.parse("ordinary assistant reply") == nil)
        precondition(DesignReview.parse(String(text.dropLast())) == nil)
        precondition(DesignReview.parse(text.replacingOccurrences(of:"\"rank\": 10",with:"\"rank\": 1")) == nil)
        precondition(DesignReview.parse(text.replacingOccurrences(of:"\"impactPerEffort\": 4",with:"\"impactPerEffort\": 6")) == nil)
        let partial="""
        {"summary":"A focused pass","limitations":"Only the composer","findings":[{"id":"f1","sentiment":"Like","title":"Clear controls","detail":"Easy to scan","evidence":"Observed: compact header","rank":1,"impactPerEffort":4}],"recommendations":[]}
        """
        precondition(DesignReview.parse(partial)?.warning != nil)
        var feedback=ReviewFeedback()
        precondition(feedback.prompt(for:review).contains("Do not implement changes"))
        feedback.ratings["f3"]="Strongly Disagree"
        feedback.notes["f3"]="The chart helps me recognise a project."
        feedback.selected=["r4"]
        feedback.clarifications["r4"]="Keep it visible by default."
        let prompt=feedback.prompt(for:review)
        precondition(prompt.contains("Strongly Disagree") && prompt.contains("Keep it visible by default."))
        precondition(prompt.contains(review.recommendations[3].action))
        precondition(!prompt.contains(review.recommendations[0].action))
        precondition(prompt.contains("Unselected recommendations are not authorised"))
        print("Review decoding, validation, feedback and selected-only scope passed.")
    }
}
