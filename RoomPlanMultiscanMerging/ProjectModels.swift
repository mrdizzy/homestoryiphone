import Foundation
import RoomPlan

// MARK: - Project Models

/// Represents a scanning project containing multiple rooms
struct ScanningProject: Codable {
    let id: UUID
    var name: String
    var createdDate: Date
    var lastModifiedDate: Date
    var roomCount: Int
    
    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.lastModifiedDate = Date()
        self.roomCount = 0
    }
    
    mutating func updateLastModified() {
        self.lastModifiedDate = Date()
    }
}

/// Manages project persistence and organization
class ProjectManager {
    static let shared = ProjectManager()
    
    private let documentsURL: URL
    private let projectsDirectoryURL: URL
    private let projectsListURL: URL
    
    private init() {
        documentsURL = FileManager.default.documentsDirectory
        projectsDirectoryURL = documentsURL.appendingPathComponent("ScanningProjects")
        projectsListURL = projectsDirectoryURL.appendingPathComponent("projects.json")
        
        // Create projects directory if it doesn't exist
        try? FileManager.default.createDirectory(at: projectsDirectoryURL, withIntermediateDirectories: true)
    }
    
    // MARK: - Project Management
    
    func loadProjects() -> [ScanningProject] {
        guard FileManager.default.fileExists(atPath: projectsListURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: projectsListURL)
            return try JSONDecoder().decode([ScanningProject].self, from: data)
        } catch {
            print("Failed to load projects: \(error)")
            return []
        }
    }
    
    func saveProjects(_ projects: [ScanningProject]) {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: projectsListURL)
        } catch {
            print("Failed to save projects: \(error)")
        }
    }
    
    func createProject(name: String) -> ScanningProject {
        var project = ScanningProject(name: name)
        
        // Create project directory
        let projectURL = getProjectDirectoryURL(for: project.id)
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        
        // Add to projects list
        var projects = loadProjects()
        projects.append(project)
        saveProjects(projects)
        
        return project
    }
    
    func updateProject(_ project: ScanningProject) {
        var projects = loadProjects()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            saveProjects(projects)
        }
    }
    
    func deleteProject(_ project: ScanningProject) {
        // Delete project directory and contents
        let projectURL = getProjectDirectoryURL(for: project.id)
        try? FileManager.default.removeItem(at: projectURL)
        
        // Remove from projects list
        var projects = loadProjects()
        projects.removeAll { $0.id == project.id }
        saveProjects(projects)
    }
    
    // MARK: - Project Directory Management
    
    func getProjectDirectoryURL(for projectId: UUID) -> URL {
        return projectsDirectoryURL.appendingPathComponent(projectId.uuidString)
    }
    
    func getRoomsDirectoryURL(for projectId: UUID) -> URL {
        return getProjectDirectoryURL(for: projectId).appendingPathComponent("Rooms")
    }
    
    func getRoomDirectoryURL(for projectId: UUID, roomName: String) -> URL {
        return getRoomsDirectoryURL(for: projectId).appendingPathComponent(roomName)
    }
    
    // MARK: - Room Management for Projects
    
    func loadScannedRooms(for projectId: UUID) -> [ScannedRoom] {
        let roomsURL = getRoomsDirectoryURL(for: projectId)
        
        guard FileManager.default.fileExists(atPath: roomsURL.path) else {
            return []
        }
        
        var scannedRooms: [ScannedRoom] = []
        
        do {
            let roomFolders = try FileManager.default.contentsOfDirectory(at: roomsURL, 
                                                                        includingPropertiesForKeys: nil, 
                                                                        options: [.skipsHiddenFiles])
            
            for folder in roomFolders where folder.hasDirectoryPath {
                let roomName = folder.lastPathComponent
                let capturedRoomURL = folder.appendingPathComponent("capturedRoom.json")
                
                if FileManager.default.fileExists(atPath: capturedRoomURL.path) {
                    do {
                        let data = try Data(contentsOf: capturedRoomURL)
                        let capturedRoom = try JSONDecoder().decode(CapturedRoom.self, from: data)
                        let scannedRoom = ScannedRoom(name: roomName, capturedRoom: capturedRoom)
                        scannedRooms.append(scannedRoom)
                    } catch {
                        print("Failed to load room \(roomName): \(error)")
                    }
                }
            }
        } catch {
            print("Failed to load rooms for project: \(error)")
        }
        
        return scannedRooms
    }
    
    func saveScannedRoom(_ room: ScannedRoom, to projectId: UUID) {
        let roomDirectoryURL = getRoomDirectoryURL(for: projectId, roomName: room.name)
        
        // Create room directory
        try? FileManager.default.createDirectory(at: roomDirectoryURL, withIntermediateDirectories: true)
        
        // Save room data
        let capturedRoomURL = roomDirectoryURL.appendingPathComponent("capturedRoom.json")
        do {
            let data = try JSONEncoder().encode(room.capturedRoom)
            try data.write(to: capturedRoomURL)
        } catch {
            print("Failed to save room \(room.name): \(error)")
        }
        
        // Update project room count
        var projects = loadProjects()
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].roomCount = loadScannedRooms(for: projectId).count
            projects[index].updateLastModified()
            saveProjects(projects)
        }
    }
    
    // MARK: - Migration Support
    
    /// Migrates existing MyHome bundle data to a default project (one-time migration)
    func migrateExistingBundleDataIfNeeded() {
        let migrationKey = "HasMigratedBundleData"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return // Already migrated
        }
        
        // Check if bundle data exists
        guard let myHomeURL = Bundle.main.url(forResource: "MyHome", withExtension: nil) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }
        
        var migratedRooms: [ScannedRoom] = []
        
        do {
            let roomFolders = try FileManager.default.contentsOfDirectory(at: myHomeURL, 
                                                                        includingPropertiesForKeys: nil, 
                                                                        options: [.skipsHiddenFiles])
            
            for folder in roomFolders where folder.hasDirectoryPath {
                let roomName = folder.lastPathComponent
                let capturedRoomURL = folder.appendingPathComponent("capturedRoom.json")
                
                if FileManager.default.fileExists(atPath: capturedRoomURL.path) {
                    do {
                        let data = try Data(contentsOf: capturedRoomURL)
                        let capturedRoom = try JSONDecoder().decode(CapturedRoom.self, from: data)
                        let scannedRoom = ScannedRoom(name: roomName, capturedRoom: capturedRoom)
                        migratedRooms.append(scannedRoom)
                    } catch {
                        print("Failed to migrate room \(roomName): \(error)")
                    }
                }
            }
            
            // Create default project if we have rooms to migrate
            if !migratedRooms.isEmpty {
                let defaultProject = createProject(name: "Sample Home")
                
                // Save migrated rooms to the default project
                for room in migratedRooms {
                    saveScannedRoom(room, to: defaultProject.id)
                }
                
                print("Migrated \(migratedRooms.count) rooms to default project")
            }
            
        } catch {
            print("Failed to migrate bundle data: \(error)")
        }
        
        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
}

// MARK: - FileManager Extension
extension FileManager {
    var documentsDirectory: URL {
        urls(for: .documentDirectory, in: .userDomainMask).first!
    }
} 