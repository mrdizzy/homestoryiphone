/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A simplified view controller for scanning and merging rooms.
*/

import UIKit
import RoomPlan
import QuickLook
import SceneKit // Added for centering logic

// Simple structure to store scanned room data
struct ScannedRoom {
    let name: String
    let capturedRoom: CapturedRoom
}

class RoomTableViewController: UITableViewController {

    /// An array of scanned rooms
    private var scannedRooms: [ScannedRoom] = []
    
    /// An object that builds a single structure by merging multiple rooms
    private let structureBuilder = StructureBuilder(options: [.beautifyObjects])
    
    /// An object that holds a merged result
    private var finalResults: CapturedStructure?
    
    /// Room capture session for continuous scanning
    private var roomCaptureSession: RoomCaptureSession?
    
    // Add these properties for QuickLook preview
    private var currentPreviewURL: URL?
    private var currentPreviewTitle: String?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Room Scanner"
        setupNavigationBar()
        loadPrescannedRooms()
        
        // Initialize room capture session for continuous scanning
        roomCaptureSession = RoomCaptureSession()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
        updateMergeButton()
    }
    
    private func setupNavigationBar() {
        let scanButton = UIBarButtonItem(title: "Scan New Room", style: .plain, target: self, action: #selector(scanNewRoom))
        navigationItem.rightBarButtonItem = scanButton
        
        let mergeButton = UIBarButtonItem(title: "Merge Rooms", style: .plain, target: self, action: #selector(mergeAndExport))
        mergeButton.isEnabled = false
        navigationItem.leftBarButtonItem = mergeButton
    }
    
    private func updateMergeButton() {
        navigationItem.leftBarButtonItem?.isEnabled = scannedRooms.count >= 2
    }

    // MARK: - Table view data source

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if scannedRooms.isEmpty {
            return 1 // Show instruction cell
        }
        return scannedRooms.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RoomCell", for: indexPath)
        
        if scannedRooms.isEmpty {
            cell.textLabel?.text = "Tap 'Scan New Room' to get started"
            cell.textLabel?.textColor = .systemGray
            cell.selectionStyle = .none
        } else {
            cell.textLabel?.text = scannedRooms[indexPath.row].name
            cell.textLabel?.textColor = .label
            cell.selectionStyle = .default
        }
        
        return cell
    }

    // MARK: - Table view delegate
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        // Don't handle tap if showing instruction cell
        guard !scannedRooms.isEmpty else { return }
        
        let selectedRoom = scannedRooms[indexPath.row]
        displayRoom(selectedRoom)
    }
    
    // MARK: - Room Display Methods
    
    private func displayRoom(_ room: ScannedRoom) {
        // Show loading indicator
        let loadingAlert = UIAlertController(title: "Preparing Room View", 
                                           message: "Loading 3D model...", 
                                           preferredStyle: .alert)
        present(loadingAlert, animated: true)
        
        Task {
            do {
                let usdzURL = try await prepareRoomForViewing(room)
                
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.presentRoomViewer(for: usdzURL, roomName: room.name)
                    }
                }
            } catch {
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.showAlert(title: "Display Error", 
                                     message: "Could not prepare room for viewing: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func prepareRoomForViewing(_ room: ScannedRoom) async throws -> URL {
        // Check for existing USDZ file first
        if let bundleURL = Bundle.main.url(forResource: "floorplan", withExtension: "usdz", subdirectory: "MyHome/\(room.name)") {
            return try await centerAndScaleUSDZ(at: bundleURL, roomName: room.name)
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let roomFolder = tempDir.appendingPathComponent("RoomViewing")
        try FileManager.default.createDirectory(at: roomFolder, withIntermediateDirectories: true)
        
        let usdzURL = roomFolder.appendingPathComponent("\(room.name).usdz")
        
        if FileManager.default.fileExists(atPath: usdzURL.path) {
            try FileManager.default.removeItem(at: usdzURL)
        }
        
        // Try exporting with different options for better viewing
        do {
            // First try with parametric export which often has better centering
            try await room.capturedRoom.export(
                to: usdzURL,
                exportOptions: [.parametric]
            )
        } catch {
            // Fallback to mesh export if parametric fails
            try await room.capturedRoom.export(
                to: usdzURL,
                exportOptions: [.mesh]
            )
        }
        
        // Apply centering and scaling for optimal viewing
        return try await centerAndScaleUSDZ(at: usdzURL, roomName: room.name)
    }
    
    /// Centers and scales a USDZ model for optimal viewing in QuickLook
    /// Following Apple's best practices for USDZ files
    private func centerAndScaleUSDZ(at sourceURL: URL, roomName: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Load the scene from the USDZ file
                    let scene = try SCNScene(url: sourceURL, options: nil)
                    
                    // Calculate the bounding box of all geometry in the scene
                    var minBounds = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
                    var maxBounds = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
                    
                    self.calculateBounds(for: scene.rootNode, minBounds: &minBounds, maxBounds: &maxBounds, transform: SCNMatrix4Identity)
                    
                    // Calculate dimensions and center
                    let size = SCNVector3(
                        maxBounds.x - minBounds.x,
                        maxBounds.y - minBounds.y,
                        maxBounds.z - minBounds.z
                    )
                    
                    // For room models: center horizontally (X,Z) but keep floor at Y=0
                    let centerX = (minBounds.x + maxBounds.x) * 0.5
                    let centerZ = (minBounds.z + maxBounds.z) * 0.5
                    // For Y, we want the bottom of the model to be at Y=0 (ground plane)
                    let floorOffset = -minBounds.y
                    
                    // Find the largest horizontal dimension for scaling (rooms are typically viewed from the side)
                    let maxHorizontalDimension = max(size.x, size.z)
                    
                    // Create optimal scaling - larger for rooms to make them easily viewable
                    // Rooms should typically be viewable at a reasonable scale
                    let targetSize: Float = 6.0 // Increased from 10.0 for better room viewing
                    let scale = maxHorizontalDimension > 0 ? targetSize / maxHorizontalDimension : 1.0
                    
                    // Apply transforms in the correct order for QuickLook
                    for child in scene.rootNode.childNodes {
                        // Step 1: Move floor to Y=0 and center horizontally
                        let positionTransform = SCNMatrix4MakeTranslation(-centerX, floorOffset, -centerZ)
                        child.transform = SCNMatrix4Mult(child.transform, positionTransform)
                        
                        // Step 2: Apply scaling around the origin
                        let scaleTransform = SCNMatrix4MakeScale(scale, scale, scale)
                        child.transform = SCNMatrix4Mult(child.transform, scaleTransform)
                        
                        // Step 3: Orient for QuickLook (most interesting view toward positive Z)
                        // For room models, a slight rotation often provides a better initial view
                        let rotationTransform = SCNMatrix4MakeRotation(Float.pi * 0.1, 1, 0, 0) // Slight downward angle
                        child.transform = SCNMatrix4Mult(child.transform, rotationTransform)
                    }
                    
                    // Export the centered scene to a new USDZ file
                    let tempDir = FileManager.default.temporaryDirectory
                    let centeredURL = tempDir.appendingPathComponent("Optimized_\(roomName)_\(UUID().uuidString).usdz")
                    
                    scene.write(to: centeredURL, options: nil, delegate: nil) { (totalProgress, error, stop) in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        
                        if totalProgress >= 1.0 {
                            continuation.resume(returning: centeredURL)
                        }
                    }
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Recursively calculates the bounding box of all geometry in a scene node hierarchy
    private func calculateBounds(for node: SCNNode, minBounds: inout SCNVector3, maxBounds: inout SCNVector3, transform: SCNMatrix4) {
        let nodeTransform = SCNMatrix4Mult(transform, node.transform)
        
        // Check if this node has geometry
        if let geometry = node.geometry {
            let (localMin, localMax) = geometry.boundingBox
            
            // Transform the 8 corners of the bounding box
            let corners = [
                SCNVector3(localMin.x, localMin.y, localMin.z),
                SCNVector3(localMin.x, localMin.y, localMax.z),
                SCNVector3(localMin.x, localMax.y, localMin.z),
                SCNVector3(localMin.x, localMax.y, localMax.z),
                SCNVector3(localMax.x, localMin.y, localMin.z),
                SCNVector3(localMax.x, localMin.y, localMax.z),
                SCNVector3(localMax.x, localMax.y, localMin.z),
                SCNVector3(localMax.x, localMax.y, localMax.z)
            ]
            
            for corner in corners {
                let transformedCorner = SCNVector3FromMatrix4(SCNMatrix4MakeTranslation(corner.x, corner.y, corner.z), nodeTransform)
                
                minBounds.x = min(minBounds.x, transformedCorner.x)
                minBounds.y = min(minBounds.y, transformedCorner.y)
                minBounds.z = min(minBounds.z, transformedCorner.z)
                
                maxBounds.x = max(maxBounds.x, transformedCorner.x)
                maxBounds.y = max(maxBounds.y, transformedCorner.y)
                maxBounds.z = max(maxBounds.z, transformedCorner.z)
            }
        }
        
        // Recursively process child nodes
        for child in node.childNodes {
            calculateBounds(for: child, minBounds: &minBounds, maxBounds: &maxBounds, transform: nodeTransform)
        }
    }
    
    private func presentRoomViewer(for usdzURL: URL, roomName: String) {
        let sceneViewController = CustomSceneViewController(usdzURL: usdzURL, roomName: roomName)
        let navController = UINavigationController(rootViewController: sceneViewController)
        present(navController, animated: true)
    }
    
    // MARK: - Scanning functionality

    @objc private func scanNewRoom() {
        presentRoomCapture()
    }
    
    private func presentRoomCapture() {
        let scanViewController = RoomScanViewController()
        scanViewController.delegate = self
        scanViewController.sharedRoomCaptureSession = roomCaptureSession
        
        let navController = UINavigationController(rootViewController: scanViewController)
        navController.modalPresentationStyle = .fullScreen
        present(navController, animated: true)
    }
    
    // MARK: - Room capture completion
    
    func roomScanCompleted(capturedRoom: CapturedRoom) {
        promptForRoomName(capturedRoom: capturedRoom)
    }
    
    private func promptForRoomName(capturedRoom: CapturedRoom) {
        let alert = UIAlertController(title: "Name Your Room", message: "Enter a name for the scanned room:", preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "e.g., Bedroom, Kitchen, Living Room"
        }
        
        let saveAction = UIAlertAction(title: "Save", style: .default) { _ in
            guard let textField = alert.textFields?.first,
                  let roomName = textField.text,
                  !roomName.isEmpty else { return }
            
            let scannedRoom = ScannedRoom(name: roomName, capturedRoom: capturedRoom)
            self.scannedRooms.append(scannedRoom)
            self.tableView.reloadData()
            self.updateMergeButton()
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(saveAction)
        alert.addAction(cancelAction)
        
        present(alert, animated: true)
    }

    // MARK: - Merging functionality

    @objc private func mergeAndExport() {
        guard scannedRooms.count >= 2 else {
            showAlert(title: "Need More Rooms", message: "Please scan at least 2 rooms before merging.")
            return
        }
        
        let capturedRoomArray = scannedRooms.map { $0.capturedRoom }
        
        // Show loading indicator
        let loadingAlert = UIAlertController(title: "Merging Rooms", message: "Please wait while we merge your rooms...", preferredStyle: .alert)
        present(loadingAlert, animated: true)
        
        Task {
            do {
                finalResults = try await structureBuilder.capturedStructure(from: capturedRoomArray)
                
                // Dismiss loading alert and show options
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.showMergeOptions()
                    }
                }
                
            } catch {
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.showAlert(title: "Merging Error", message: error.localizedDescription)
                    }
                }
            }
        }
    }
    
    private func showMergeOptions() {
        let alert = UIAlertController(title: "Merge Complete", 
                                    message: "Your rooms have been successfully merged. What would you like to do?", 
                                    preferredStyle: .actionSheet)
        
        let previewAction = UIAlertAction(title: "Preview Merged Structure", style: .default) { _ in
            self.previewMergedStructure()
        }
        
        let exportAction = UIAlertAction(title: "Export Files", style: .default) { _ in
            self.exportMergedStructure()
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(previewAction)
        alert.addAction(exportAction)
        alert.addAction(cancelAction)
        
        // Configure for iPad
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }
        
        present(alert, animated: true)
    }
    
    private func previewMergedStructure() {
        guard let finalResults = finalResults else {
            showAlert(title: "Error", message: "No merged structure available to preview.")
            return
        }
        
        // Show loading indicator
        let loadingAlert = UIAlertController(title: "Preparing Preview", 
                                           message: "Loading merged structure...", 
                                           preferredStyle: .alert)
        present(loadingAlert, animated: true)
        
        Task {
            do {
                let previewURL = try await prepareMergedStructureForViewing(finalResults)
                
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.presentMergedStructureViewer(for: previewURL)
                    }
                }
            } catch {
                await MainActor.run {
                    loadingAlert.dismiss(animated: true) {
                        self.showAlert(title: "Preview Error", 
                                     message: "Could not prepare merged structure for viewing: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func prepareMergedStructureForViewing(_ capturedStructure: CapturedStructure) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let previewFolder = tempDir.appendingPathComponent("MergedStructurePreview")
        try FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
        
        let usdzURL = previewFolder.appendingPathComponent("MergedStructure_Preview.usdz")
        
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: usdzURL.path) {
            try FileManager.default.removeItem(at: usdzURL)
        }
        
        // Create metadata URL (required for export)
        let metadataURL = previewFolder.appendingPathComponent("MergedStructure_Preview.plist")
        
        // Export the merged structure
        try await capturedStructure.export(
            to: usdzURL,
            metadataURL: metadataURL,
            exportOptions: [.mesh]
        )
        
        // Apply centering and scaling for optimal viewing
        return try await centerAndScaleUSDZ(at: usdzURL, roomName: "Merged Structure")
    }
    
    private func presentMergedStructureViewer(for usdzURL: URL) {
        let sceneViewController = CustomSceneViewController(usdzURL: usdzURL, roomName: "Merged Structure")
        
        // Add export button to the preview
        let exportButton = UIBarButtonItem(title: "Export", style: .plain, target: self, action: #selector(exportFromPreview))
        sceneViewController.navigationItem.leftBarButtonItem = exportButton
        
        let navController = UINavigationController(rootViewController: sceneViewController)
        present(navController, animated: true)
    }
    
    @objc private func exportFromPreview() {
        // Dismiss the preview first, then export
        presentedViewController?.dismiss(animated: true) {
            self.exportMergedStructure()
        }
    }
    
    private func exportMergedStructure() {
        do {
            let exportFolderURL = try createTmpExportFolder()
            let meshDestinationURL = exportFolderURL.appending(path: "MergedRooms.usdz")
            
            try createExportData(meshDestinationURL: meshDestinationURL)
            
            let activityVC = UIActivityViewController(activityItems: [exportFolderURL], applicationActivities: nil)
            activityVC.modalPresentationStyle = .popover
            activityVC.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
            
            present(activityVC, animated: true)
            
        } catch {
            showAlert(title: "Export Error", message: error.localizedDescription)
        }
    }
    
    /// Exports the merged captured structure in JSON and USDZ formats to a URL.
    private func createExportData(meshDestinationURL: URL) throws {
        guard let finalResults else { return }
        
        let roomDestinationURL = meshDestinationURL.deletingPathExtension().appendingPathExtension("json")
        try exportJson(from: finalResults, to: roomDestinationURL)
        
        let metadataDestinationURL = meshDestinationURL.deletingPathExtension().appendingPathExtension("plist")
        try finalResults.export(to: meshDestinationURL,
                                metadataURL: metadataDestinationURL,
                                exportOptions: [.mesh])
    }
    
    /// Exports the given captured structure in JSON format to a URL.
    private func exportJson(from capturedStructure: CapturedStructure, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(capturedStructure)
        try data.write(to: url)
    }
    
    /// Provides a temporary location on disk to export a 3D model to.
    private func createTmpExportFolder(
        tmpFolderURL: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let exportFolderURL = tmpFolderURL.appending(path: "MultiscanMergedExport")
        if FileManager.default.fileExists(atPath: exportFolderURL.path()) {
            try FileManager.default.removeItem(at: exportFolderURL)
        }
        try FileManager.default.createDirectory(at: exportFolderURL,
                                                withIntermediateDirectories: true)
        return exportFolderURL
    }
    
    private func loadPrescannedRooms() {
        guard let myHomeURL = Bundle.main.url(forResource: "MyHome", withExtension: nil) else { return }
        
        let fileManager = FileManager.default
        do {
            let roomFolders = try fileManager.contentsOfDirectory(at: myHomeURL, 
                                                                includingPropertiesForKeys: nil, 
                                                                options: [.skipsHiddenFiles])
            
            for folder in roomFolders where folder.hasDirectoryPath {
                let roomName = folder.lastPathComponent
                let capturedRoomURL = folder.appendingPathComponent("capturedRoom.json")
                
                if fileManager.fileExists(atPath: capturedRoomURL.path) {
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
            
            DispatchQueue.main.async {
                self.tableView.reloadData()
                self.updateMergeButton()
            }
        } catch {
            print("Failed to load prescanned rooms: \(error)")
        }
    }
}

// MARK: - Alert helper
extension RoomTableViewController {
    func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - QuickLook Data Source
extension RoomTableViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return currentPreviewURL != nil ? 1 : 0
    }
    
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        guard let url = currentPreviewURL else {
            fatalError("Preview URL should not be nil")
        }
        
        return RoomPreviewItem(url: url, title: currentPreviewTitle ?? "Room Model")
    }
}

// MARK: - QuickLook Delegate
extension RoomTableViewController: QLPreviewControllerDelegate {
    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
        return .disabled  // Disable editing if not needed
    }
    
    func previewController(_ controller: QLPreviewController, transitionViewFor item: QLPreviewItem) -> UIView? {
        return nil  // Use default transition
    }
}

// Helper class for QuickLook preview
class RoomPreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String
    
    var previewItemURL: URL? { return url }
    var previewItemTitle: String? { return title }
    
    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

// MARK: - Room Scan View Controller
class RoomScanViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    
    weak var delegate: RoomTableViewController?
    var sharedRoomCaptureSession: RoomCaptureSession?
    
    private var roomCaptureView: RoomCaptureView!
    private var isScanning = false
    private var finalResults: CapturedRoom?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Scan Room"
        setupUI()
        setupRoomCapture()
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        let doneButton = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneScanning))
        let cancelButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelScanning))
        
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = doneButton
    }
    
    private func setupRoomCapture() {
        // Create RoomCaptureView with custom session if available
        if let sharedSession = sharedRoomCaptureSession {
            roomCaptureView = RoomCaptureView(frame: view.bounds, arSession: sharedSession.arSession)
        } else {
            roomCaptureView = RoomCaptureView(frame: view.bounds)
        }
        
        roomCaptureView.delegate = self
        roomCaptureView.captureSession.delegate = self
        
        view.addSubview(roomCaptureView)
        
        // Auto-layout constraints
        roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            roomCaptureView.topAnchor.constraint(equalTo: view.topAnchor),
            roomCaptureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomCaptureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            roomCaptureView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isScanning {
            stopSession()
        }
    }
    
    private func startSession() {
        guard !isScanning else { return }
        
        isScanning = true
        
        // Use continuous ARSession for multi-room scanning (pauseARSession: false)
        roomCaptureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }
    
    private func stopSession() {
        guard isScanning else { return }
        
        isScanning = false
        // Don't pause ARSession to maintain continuity for next scan
        roomCaptureView.captureSession.stop(pauseARSession: false)
    }
    
    @objc private func doneScanning() {
        stopSession()
    }
    
    @objc private func cancelScanning() {
        if isScanning {
            stopSession()
        }
        dismiss(animated: true)
    }
    
    // MARK: - RoomCaptureViewDelegate
    
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return true
    }
    
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.showAlert(title: "Scan Error", message: error.localizedDescription)
            }
            return
        }
        
        finalResults = processedResult
        
        // Dismiss the scanning view and pass the result back
        DispatchQueue.main.async {
            self.dismiss(animated: true) {
                self.delegate?.roomScanCompleted(capturedRoom: processedResult)
            }
        }
    }
    
    // MARK: - RoomCaptureSessionDelegate
    
    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        // Optional: Handle real-time updates during scanning
    }
    
    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        // Optional: Handle real-time updates during scanning
    }
    
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        // Optional: Handle scanning instructions
    }
    
    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        // Optional: Handle session start
    }
    
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        // Optional: Handle session end
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - SceneKit Helper Extensions
extension RoomTableViewController {
    /// Helper function to transform a vector by a matrix
    private func SCNVector3FromMatrix4(_ translation: SCNMatrix4, _ transform: SCNMatrix4) -> SCNVector3 {
        let combined = SCNMatrix4Mult(translation, transform)
        return SCNVector3(combined.m41, combined.m42, combined.m43)
    }
}

// Add this new custom scene viewer class
class CustomSceneViewController: UIViewController {
    private let usdzURL: URL
    private let roomName: String
    private var sceneView: SCNView!
    
    init(usdzURL: URL, roomName: String) {
        self.usdzURL = usdzURL
        self.roomName = roomName
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = roomName
        view.backgroundColor = .systemBackground
        
        let doneButton = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissViewer))
        navigationItem.rightBarButtonItem = doneButton
        
        setupSceneView()
    }
    
    private func setupSceneView() {
        sceneView = SCNView()
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.backgroundColor = .systemBackground
        sceneView.allowsCameraControl = true // Allow user to rotate/zoom
        sceneView.antialiasingMode = .multisampling4X
        
        view.addSubview(sceneView)
        
        NSLayoutConstraint.activate([
            sceneView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        loadScene()
    }
    
    private func loadScene() {
        do {
            let scene = try SCNScene(url: usdzURL, options: nil)
            sceneView.scene = scene
            
            // Set up lighting
            sceneView.autoenablesDefaultLighting = true
            
            // Set up camera
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 5, 10) // Position camera above and back
            cameraNode.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(cameraNode)
            
        } catch {
            let alert = UIAlertController(title: "Error", message: "Could not load 3D model: \(error.localizedDescription)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                self.dismissViewer()
            })
            present(alert, animated: true)
        }
    }
    
    @objc private func dismissViewer() {
        dismiss(animated: true)
    }
}
