import SwiftUI

/// Expansion belongs to an exchange, so streaming updates do not reset it.
struct ComposerWorkSection<Content:View>:View {
    let exchange:ComposerExchange
    let active:Bool
    let status:String
    let startedAt:Double?
    let waiting:Bool
    let textScale:Double
    @ViewBuilder let content:()->Content
    @StoredState private var expanded=false
    private var hasDetails:Bool {exchange.messages.contains{$0.role != "You" && $0.role != "Work" && !exchange.responseIDs(active:active).contains($0.id)}}
    var body:some View {
        if active || exchange.work != nil || hasDetails {
            VStack(alignment:.leading,spacing:10) {
                DisclosureGroup(isExpanded:$expanded) {content()} label: {
                    HStack(spacing:8) {
                        if active && !waiting {ProgressView().controlSize(.small)}
                        if waiting && active {Image(systemName:"hand.raised").foregroundStyle(.orange)}
                        Text(active ? (status == "Working…" ? "Working for" : status) : (exchange.work?.durationSeconds == nil ? "Work details" : "Worked for"))
                        if active,let startedAt {
                            Text(Date(timeIntervalSince1970:startedAt),style:.timer).monospacedDigit().fixedSize()
                        } else if let duration=exchange.work?.durationSeconds {
                            Text(Self.duration(duration)).monospacedDigit()
                        }
                    }
                    .font(.system(size:13*textScale)).foregroundStyle(.secondary)
                }
                if active && !expanded,let latest=exchange.messages.last(where:{$0.role != "Work" && $0.role != "You"}) {
                    Text(latest.role == "Thinking" ? "Thinking · " + latest.text : latest.text)
                        .font(.system(size:13*textScale)).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
                Divider()
            }.padding(.vertical,6)
        }
    }
    static func duration(_ value:Double)->String {
        let seconds=value.isFinite ? Int(min(max(0,value),1e12)) : 0
        if seconds>=3600 {return "\(seconds/3600)h \((seconds%3600)/60)m \(seconds%60)s"}
        if seconds>=60 {return "\(seconds/60)m \(seconds%60)s"}
        return "\(seconds)s"
    }
}
