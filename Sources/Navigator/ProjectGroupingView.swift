import SwiftUI

struct ProjectGroupingView:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    let projects:[Project]
    let save:(Set<String>,String,@escaping (String?)->Void)->Void
    @Environment(\.dismiss) private var dismiss
    @Binding var selection:Set<String>
    @Binding var name:String
    @StoredState private var search=""
    @StoredState private var saving=false
    @StoredState private var saveError:String?

    private var groups:[String] {Array(Set(projects.map(\.group).filter{!$0.isEmpty})).sorted()}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Group projects").font(.title2.bold())
            Text("Choose the projects to place together in Navigator.").foregroundStyle(.secondary)
            HStack {
                TextField("Group name",text:$name)
                if !groups.isEmpty {
                    Menu("Existing group") {ForEach(groups,id:\.self) {group in Button(group) {name=group}}}
                }
            }
            TextField("Find a project",text:$search)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(projects.filter {search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}) {project in
                        Toggle(isOn:Binding(get:{selection.contains(project.id)},set:{on in
                            if on {selection.insert(project.id)} else {selection.remove(project.id)}
                        })) {
                            HStack {
                                ProjectIcon(project:project,size:22)
                                VStack(alignment:.leading) {
                                    Text(project.name)
                                    if !project.group.isEmpty {Text(project.group).font(.system(size:12*textScale)).foregroundStyle(.secondary)}
                                }
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.padding(4)
            }.frame(height:260)
            Text("Only Navigator’s organisation changes. Codex projects and folders stay as they are.")
                .font(.system(size:12*textScale)).foregroundStyle(.secondary)
            HStack {
                Text("\(selection.count) selected").font(.system(size:12*textScale))
                Spacer()
                Button("Cancel",role:.cancel) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Group") {saving=true;saveError=nil;save(selection,name.trimmingCharacters(in:.whitespacesAndNewlines)) {error in saving=false;saveError=error;if error == nil {dismiss()}}}
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || selection.isEmpty || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || name.count>120)
            }
            if let saveError {Text(saveError).foregroundStyle(.red)}
        }.padding(24).frame(width:480)
            .background(Color(nsColor:.windowBackgroundColor))
    }
}
