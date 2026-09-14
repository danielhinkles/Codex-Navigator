import SwiftUI
import AppKit

private struct CreatedProjectResponse:Decodable {let project:Project}

struct NewProjectView:View {
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    let created:(Project)->Void
    @StoredState private var name=""
    @StoredState private var folder:URL?
    @StoredState private var creating=false
    @StoredState private var error:String?
    @StoredState private var requestKey=UUID().uuidString
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Label("New Project",systemImage:"folder.badge.plus").font(.title2.bold())
            Text("Create a project shared with Codex. Its sessions will use the folder you choose.").foregroundStyle(.secondary)
            TextField("Project name",text:$name).textFieldStyle(.roundedBorder)
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(folder?.lastPathComponent ?? "No folder selected").fontWeight(.medium)
                    if let folder {Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                }
                Spacer()
                Button("Choose folder…") {chooseFolder()}
            }
            Text("Choose an existing folder, or use New Folder in the picker to start fresh.").font(.caption).foregroundStyle(.secondary)
            if let error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
            HStack {
                Spacer()
                Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create Project") {create()}.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder == nil || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:480).disabled(creating).interactiveDismissDisabled(creating)
        .onAppear {
            if InteractionProbe.enabled {
                InteractionProbe.actions["createProject"]={
                    let root=ComposerLocalState.defaultDirectory().appendingPathComponent("creation-check",isDirectory:true)
                    try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    name="Navigator Creation Check";folder=root;create()
                }
            }
        }
        .onChange(of:name) {_,_ in requestKey=UUID().uuidString}
        .onChange(of:folder) {_,_ in requestKey=UUID().uuidString}
    }
    private func chooseFolder() {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true
        panel.canCreateDirectories=true;panel.allowsMultipleSelection=false;panel.prompt="Use Folder"
        panel.message="Choose a project folder, or click New Folder to create one."
        panel.begin {response in
            guard response == .OK,let url=panel.url else {return}
            folder=url
            if name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {name=url.lastPathComponent}
        }
    }
    private func create() {
        guard let folder else {return}
        creating=true;error=nil
        model.request(["action":"createProject","name":name,"path":folder.path,"idempotencyKey":requestKey],as:CreatedProjectResponse.self) {result in
            creating=false
            switch result {
            case .success(let value):dismiss();created(value.project)
            case .failure(let failure):error=failure.localizedDescription
            }
        }
    }
}

struct NewSessionView:View {
    let projects:[Project]
    let initialProject:String?
    let create:(Project?)->Void
    @Environment(\.dismiss) private var dismiss
    @StoredState private var selected=""
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Label("New Session",systemImage:"square.and.pencil").font(.title2.bold())
            Picker("Project",selection:$selected) {
                Text("No project").tag("")
                ForEach(projects) {project in Text(project.name).tag(project.id)}
            }
            Text(selected.isEmpty ? "Start a standalone session in its own working folder." : projects.first(where:{$0.id == selected})?.path ?? "")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction)
                Button("New Session") {dismiss();create(projects.first(where:{$0.id == selected}))}
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:440)
        .onAppear {
            selected=initialProject ?? ""
            if InteractionProbe.enabled {InteractionProbe.actions["createSession"]={dismiss();create(projects.first(where:{$0.id == selected}))}}
        }
    }
}
