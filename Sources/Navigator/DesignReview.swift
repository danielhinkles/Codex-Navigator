import SwiftUI

struct DesignReviewView:View {
    let review:DesignReview
    let reviewID:String
    @Binding var feedback:ReviewFeedback
    let prepare:(String)->Void
    @AppStorage("navigator.textScale") private var textScale=1.0
    private let ratings=["Strongly Agree","Mildly Agree","Mildly Disagree","Strongly Disagree"]
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(review.summary).font(.system(size:16*textScale,weight:.medium)).textSelection(.enabled)
            if let warning=review.warning {
                Label(warning,systemImage:"exclamationmark.triangle.fill").font(.system(size:12*textScale)).foregroundStyle(.orange)
            }
            DisclosureGroup("Review scope") {Text(review.limitations).textSelection(.enabled)}
            findings(positive:true)
            findings(positive:false)
            VStack(alignment:.leading,spacing:10) {
                Text("Next pass").font(.system(size:17*textScale,weight:.semibold)).id("recommendations-" + reviewID)
                Text("Select what to implement. Clarifications are optional.").foregroundStyle(.secondary)
                ForEach(review.recommendations) {r in
                    VStack(alignment:.leading,spacing:8) {
                        Toggle(r.title,isOn:Binding(get:{feedback.selected.contains(r.id)},set:{if $0 {feedback.selected.insert(r.id)} else {feedback.selected.remove(r.id)}})).toggleStyle(.checkbox).fontWeight(.medium)
                        Text(r.action).textSelection(.enabled)
                        Text(r.benefit + " · " + r.effort).foregroundStyle(.secondary)
                        DisclosureGroup("Add clarification") {TextField("What should change or stay?",text:Binding(get:{feedback.clarifications[r.id] ?? ""},set:{feedback.clarifications[r.id]=$0}),axis:.vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)}
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                }
                Button(feedback.selected.isEmpty ? "Prepare feedback" : "Prepare \(feedback.selected.count) selected recommendations") {prepare(feedback.prompt(for:review))}.buttonStyle(.borderedProminent)
                Text("Creates an editable draft. Nothing is sent until you choose Send to Codex.").font(.system(size:11*textScale)).foregroundStyle(.secondary)
            }
        }.font(.system(size:13*textScale))
    }
    private func findings(positive:Bool)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text(positive ? "What’s working" : "What needs attention").font(.system(size:17*textScale,weight:.semibold))
            ForEach(review.findings.filter{["Love","Like"].contains($0.sentiment) == positive}.sorted{$0.rank < $1.rank}) {f in
                VStack(alignment:.leading,spacing:8) {
                    HStack(alignment:.firstTextBaseline) {
                        Text(f.sentiment).foregroundStyle(positive ? Color.green : Color.orange).fontWeight(.semibold)
                        Text(f.title).fontWeight(.semibold)
                        Spacer(minLength:0)
                    }
                    Text(f.detail).textSelection(.enabled)
                    HStack {
                        Text("Priority \(f.rank) · Impact per Effort \(f.impactPerEffort)/5").foregroundStyle(.secondary)
                            .help("Estimate: 5 = high user value for little effort; 1 = low value for substantial effort. Strengths score opportunities to build on them.")
                        Spacer(minLength:4)
                        Picker("Your view",selection:Binding(get:{feedback.ratings[f.id] ?? ""},set:{feedback.ratings[f.id]=$0})) {
                            Text("Your view…").tag("")
                            ForEach(ratings,id:\.self) {Text($0).tag($0)}
                        }.labelsHidden().fixedSize().accessibilityLabel("Your view on " + f.title)
                    }.font(.system(size:11*textScale))
                    DisclosureGroup("Evidence & your explanation") {
                        Text(f.evidence).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                        TextField("Explain your position (optional)",text:Binding(get:{feedback.notes[f.id] ?? ""},set:{feedback.notes[f.id]=$0}),axis:.vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                    }
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            }
        }
    }
}
