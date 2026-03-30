import SwiftUI
import SwiftData

enum OrganizationTab: String, CaseIterable {
    case departments = "Departments & Teams"
    case roleLevels = "Role Levels"
    case roles = "Roles"
}

struct OrganizationSettingsView: View {
    @State private var selectedTab: OrganizationTab = .departments

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(OrganizationTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedTab {
            case .departments:
                DepartmentsTeamsTab()
            case .roleLevels:
                RoleLevelsTab()
            case .roles:
                RolesTab()
            }
        }
    }
}

// MARK: - Departments & Teams

private struct DepartmentsTeamsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Department.sortOrder) private var departments: [Department]
    @State private var newDepartmentName = ""
    @State private var newTeamNames: [UUID: String] = [:]

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("New department name...", text: $newDepartmentName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addDepartment() }
                    Button("Add") { addDepartment() }
                        .disabled(newDepartmentName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Label("Add Department", systemImage: "building.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            ForEach(departments) { dept in
                Section {
                    // Department name (editable)
                    HStack {
                        Image(systemName: "building.2")
                            .foregroundStyle(.cyan)
                        TextField("Department", text: Binding(
                            get: { dept.name },
                            set: { dept.name = $0 }
                        ))
                        .font(.headline)
                    }

                    // Teams within department
                    ForEach(dept.teams.sorted { $0.sortOrder < $1.sortOrder }) { team in
                        HStack {
                            Image(systemName: "person.3")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField("Team name", text: Binding(
                                get: { team.name },
                                set: { team.name = $0 }
                            ))
                            Spacer()
                            Button {
                                dept.teams.removeAll { $0.id == team.id }
                                modelContext.delete(team)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 8)
                    }

                    // Add team
                    HStack {
                        TextField("New team name...", text: Binding(
                            get: { newTeamNames[dept.id] ?? "" },
                            set: { newTeamNames[dept.id] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTeam(to: dept) }
                        Button("Add Team") { addTeam(to: dept) }
                            .controlSize(.small)
                            .disabled((newTeamNames[dept.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.leading, 8)
                } header: {
                    HStack {
                        Text(dept.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                        Spacer()
                        Button(role: .destructive) {
                            modelContext.delete(dept)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addDepartment() {
        let name = newDepartmentName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let dept = Department(name: name, sortOrder: departments.count)
        modelContext.insert(dept)
        newDepartmentName = ""
    }

    private func addTeam(to dept: Department) {
        let name = (newTeamNames[dept.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let team = Team(name: name, sortOrder: dept.teams.count)
        team.department = dept
        dept.teams.append(team)
        newTeamNames[dept.id] = ""
    }
}

// MARK: - Role Levels

private struct RoleLevelsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoleLevel.sortOrder) private var levels: [RoleLevel]
    @State private var newLevelName = ""
    @State private var newLevelCategory: RoleLevelCategory = .ic

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("New role level name...", text: $newLevelName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addLevel() }
                    Picker("", selection: $newLevelCategory) {
                        ForEach(RoleLevelCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .frame(width: 180)
                    Button("Add") { addLevel() }
                        .disabled(newLevelName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Label("Add Role Level", systemImage: "person.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            ForEach(RoleLevelCategory.allCases, id: \.self) { category in
                let categoryLevels = levels.filter { $0.category == category }
                if !categoryLevels.isEmpty {
                    Section {
                        ForEach(categoryLevels) { level in
                            HStack {
                                TextField("Level name", text: Binding(
                                    get: { level.name },
                                    set: { level.name = $0 }
                                ))
                                Spacer()
                                Button {
                                    modelContext.delete(level)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text(category.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addLevel() {
        let name = newLevelName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let level = RoleLevel(name: name, category: newLevelCategory, sortOrder: levels.count)
        modelContext.insert(level)
        newLevelName = ""
    }
}

// MARK: - Roles

private struct RolesTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InterviewRole.createdAt) private var roles: [InterviewRole]
    @Query(sort: \Department.sortOrder) private var departments: [Department]
    @Query(sort: \RoleLevel.sortOrder) private var levels: [RoleLevel]

    @State private var selectedDepartment: Department?
    @State private var selectedTeam: Team?
    @State private var selectedLevel: RoleLevel?
    @State private var customTitle = ""

    private var availableTeams: [Team] {
        (selectedDepartment?.teams ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Picker("Department", selection: $selectedDepartment) {
                        Text("None").tag(nil as Department?)
                        ForEach(departments) { dept in
                            Text(dept.name).tag(dept as Department?)
                        }
                    }
                    .frame(maxWidth: 180)

                    if !availableTeams.isEmpty {
                        Picker("Team", selection: $selectedTeam) {
                            Text("None").tag(nil as Team?)
                            ForEach(availableTeams) { team in
                                Text(team.name).tag(team as Team?)
                            }
                        }
                        .frame(maxWidth: 160)
                    }

                    Picker("Level", selection: $selectedLevel) {
                        Text("Select...").tag(nil as RoleLevel?)
                        ForEach(levels) { level in
                            Text(level.name).tag(level as RoleLevel?)
                        }
                    }
                    .frame(maxWidth: 200)
                }

                HStack {
                    TextField("Custom title (optional)", text: $customTitle)
                        .textFieldStyle(.roundedBorder)
                    Button("Add Role") { addRole() }
                        .disabled(selectedLevel == nil)
                }
            } header: {
                Label("Add Role", systemImage: "person.badge.shield.checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            if !roles.isEmpty {
                Section {
                    ForEach(roles) { role in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(role.displayTitle)
                                    .font(.body)
                                Text(role.fullDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                modelContext.delete(role)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Label("Roles (\(roles.count))", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedDepartment) { _, _ in
            selectedTeam = nil
        }
    }

    private func addRole() {
        guard let level = selectedLevel else { return }
        let title = customTitle.trimmingCharacters(in: .whitespaces)
        let role = InterviewRole(
            level: level,
            department: selectedDepartment,
            team: selectedTeam,
            customTitle: title.isEmpty ? nil : title
        )
        modelContext.insert(role)
        customTitle = ""
        selectedLevel = nil
    }
}
