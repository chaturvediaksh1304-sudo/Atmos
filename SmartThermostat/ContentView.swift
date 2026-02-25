import SwiftUI
import RealityKit
import ARKit
import Vision
import CoreML
import Combine
import CoreLocation

// --- APP STATE MANAGEMENT ---
enum AppState {
    case splash
    case roomSelection
    case scanning
    case analyzing // NEW: The psychological anticipation phase
    case results
}

// --- DATA MODELS ---
enum RoomCategory: String, Codable, CaseIterable {
    case home = "Home"
    case office = "Office"
    case other = "Other"
    
    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .office: return "briefcase.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .home: return .cyan
        case .office: return .orange
        case .other: return .purple
        }
    }
}

struct SavedRoom: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var volume: Double
    var category: RoomCategory
}

struct ContentView: View {
    @State private var appState: AppState = .splash
    @StateObject var arManager = ARManager()
    @StateObject var weatherManager = WeatherManager()
    
    // --- PERSISTENT STATE (MEMORY) ---
    @AppStorage("savedRooms") private var savedRoomsData: Data = Data()
    @State private var savedRooms: [SavedRoom] = []
    
    @AppStorage("comfortOffset") private var comfortOffset: Double = 0.0
    @AppStorage("isEcoMode") private var isEcoMode: Bool = false
    
    // --- CURRENT SCAN STATE ---
    @State private var activeRoom: SavedRoom? = nil
    @State private var rawTargetTempF: Double? = nil
    @State private var peopleCount: Int = 0
    @State private var estimatedVolume: Double = 1500.0
    @State private var isCelsius: Bool = false
    
    // Haptics Generator
    let hapticImpact = UIImpactFeedbackGenerator(style: .rigid)
    
    var body: some View {
        ZStack {
            // 1. BACKGROUND: THE CAMERA
            ARCameraView(arManager: arManager)
                .edgesIgnoringSafeArea(.all)
                .opacity((appState == .splash || appState == .roomSelection) ? 0 : 1)
                .blur(radius: appState == .analyzing ? 20 : 0) // Cinematic blur during analysis
            
            // 2. BACKGROUND: PREMIUM AURA GRADIENT
            if appState == .splash || appState == .roomSelection {
                PremiumBackground()
            }
            
            // 3. STATE VIEWS
            switch appState {
            case .splash:
                SplashScreen(isActive: $appState)
                    .onAppear { loadRooms() }
                
            case .roomSelection:
                RoomSelectionView(
                    rooms: $savedRooms,
                    isEcoMode: $isEcoMode,
                    onSelectRoom: { room in
                        hapticImpact.impactOccurred()
                        self.activeRoom = room
                        self.estimatedVolume = room.volume
                        startScanning()
                    },
                    onNewRoom: {
                        hapticImpact.impactOccurred()
                        self.activeRoom = nil
                        self.estimatedVolume = 1500.0
                        startScanning()
                    },
                    onDeleteRoom: deleteRoom
                )
                
            case .scanning:
                ScanningOverlay(
                    activeRoomName: activeRoom?.name,
                    people: arManager.detectedPeople,
                    volume: estimatedVolume,
                    isVolumeLocked: activeRoom != nil,
                    onAnalyze: triggerAnalysis,
                    onCancel: { withAnimation { appState = .roomSelection } }
                )
                
            case .analyzing:
                AnalyzingView() // The Anticipation Builder
                
            case .results:
                ResultsView(
                    targetTempF: calculateFinalTemp(),
                    outdoorTempF: weatherManager.outdoorTemp,
                    humidity: weatherManager.humidity,
                    people: peopleCount,
                    volume: estimatedVolume,
                    city: weatherManager.city,
                    isCelsius: $isCelsius,
                    isEcoMode: isEcoMode,
                    comfortOffset: $comfortOffset,
                    activeRoom: activeRoom,
                    onSaveRoom: saveCurrentRoom,
                    onRetake: {
                        hapticImpact.impactOccurred()
                        withAnimation {
                            appState = .scanning
                            rawTargetTempF = nil
                        }
                    },
                    onHome: {
                        hapticImpact.impactOccurred()
                        withAnimation { appState = .roomSelection }
                    }
                )
            }
        }
        .onAppear {
            weatherManager.requestLocation()
            hapticImpact.prepare()
        }
        .onReceive(arManager.$detectedPeople) { count in
            if appState == .scanning && count != peopleCount {
                // Haptic feedback every time a new person is detected
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.peopleCount = count
            }
        }
        .onReceive(arManager.$estimatedDistance) { dist in
            if appState == .scanning && activeRoom == nil {
                let roomWidth = dist * 2.0
                let volumeM3 = (roomWidth * roomWidth) * 2.4
                self.estimatedVolume = Double(volumeM3 * 35.315)
            }
        }
    }
    
    // --- ACTIONS ---
    func startScanning() {
        arManager.resumeSession()
        withAnimation(.easeInOut) { appState = .scanning }
    }
    
    func triggerAnalysis() {
        hapticImpact.impactOccurred()
        arManager.pauseSession()
        
        // 1. Move to analyzing state to build psychological anticipation
        withAnimation(.easeIn(duration: 0.4)) {
            appState = .analyzing
        }
        
        // 2. Crunch the AI in the background
        calculateAI()
        
        // 3. Wait 1.8 seconds for dramatic effect, then show results
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            let successHaptic = UINotificationFeedbackGenerator()
            successHaptic.notificationOccurred(.success)
            
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                appState = .results
            }
        }
    }
    
    func calculateFinalTemp() -> Double? {
        guard let baseTemp = rawTargetTempF else { return nil }
        var finalTemp = baseTemp + comfortOffset
        if isEcoMode {
            let outdoor = weatherManager.outdoorTemp ?? 72.0
            if outdoor > finalTemp { finalTemp += 2.0 } else { finalTemp -= 2.0 }
        }
        return finalTemp
    }
    
    func calculateAI() {
        do {
            let config = MLModelConfiguration()
            let model = try SmartTemp(configuration: config)
            let currentOutdoor = weatherManager.outdoorTemp ?? 72.0
            let input = SmartTempInput(outdoorTemp: currentOutdoor, roomVolume: estimatedVolume, numPeople: Double(peopleCount))
            let prediction = try model.prediction(input: input)
            self.rawTargetTempF = prediction.targetTemp
        } catch {
            print("ML Error: \(error)")
            self.rawTargetTempF = nil
        }
    }
    
    // --- PERSISTENCE LOGIC ---
    func loadRooms() {
        if let decoded = try? JSONDecoder().decode([SavedRoom].self, from: savedRoomsData) { savedRooms = decoded }
    }
    func saveCurrentRoom(name: String, category: RoomCategory) {
        let newRoom = SavedRoom(name: name, volume: estimatedVolume, category: category)
        savedRooms.append(newRoom)
        activeRoom = newRoom
        if let encoded = try? JSONEncoder().encode(savedRooms) { savedRoomsData = encoded }
    }
    func deleteRoom(room: SavedRoom) {
        savedRooms.removeAll { $0.id == room.id }
        if let encoded = try? JSONEncoder().encode(savedRooms) { savedRoomsData = encoded }
    }
}

// --- PREMIUM BACKGROUND AURA ---
struct PremiumBackground: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08).edgesIgnoringSafeArea(.all)
            Circle().fill(LinearGradient(colors: [.blue.opacity(0.4), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 400, height: 400).blur(radius: 80).offset(x: animate ? 50 : -50, y: animate ? -30 : 50)
                .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: animate)
            Circle().fill(LinearGradient(colors: [.cyan.opacity(0.3), .clear], startPoint: .bottom, endPoint: .top))
                .frame(width: 300, height: 300).blur(radius: 60).offset(x: animate ? -60 : 60, y: animate ? 100 : 0)
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: animate)
        }.onAppear { animate = true }
    }
}

// --- VIEW 1: SPLASH SCREEN ---
struct SplashScreen: View {
    @Binding var isActive: AppState
    @State private var opacity = 0.0
    var body: some View {
        VStack(spacing: 20) {
            Text("ATMOS").font(.system(size: 45, weight: .black)).tracking(12).foregroundColor(.white)
                .shadow(color: .cyan.opacity(0.5), radius: 20, x: 0, y: 0)
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 1.0)) { opacity = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { isActive = .roomSelection } }
        }
    }
}

// --- VIEW 2: ROOM SELECTION ---
struct RoomSelectionView: View {
    @Binding var rooms: [SavedRoom]
    @Binding var isEcoMode: Bool
    var onSelectRoom: (SavedRoom) -> Void
    var onNewRoom: () -> Void
    var onDeleteRoom: (SavedRoom) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Text("Select Zone").font(.system(size: 32, weight: .bold)).foregroundColor(.white).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.top, 80).padding(.bottom, 20)
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Eco Mode").font(.headline).foregroundColor(.white)
                    Text("Prioritize energy efficiency").font(.caption).foregroundColor(.gray)
                }
                Spacer()
                Toggle("", isOn: $isEcoMode).labelsHidden().tint(.green)
            }
            .padding(20).background(.ultraThinMaterial).cornerRadius(24)
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.0)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .padding(.horizontal, 25).padding(.bottom, 30)
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 15) {
                    ForEach(rooms) { room in RoomCard(room: room) { onSelectRoom(room) } onDelete: { onDeleteRoom(room) } }
                }
                .padding(.horizontal, 25).padding(.bottom, 100)
            }
        }
        .overlay(
            VStack {
                Spacer()
                Button(action: onNewRoom) {
                    HStack { Image(systemName: "viewfinder"); Text("Scan New Room").font(.system(.headline)).bold() }
                    .foregroundColor(.white).padding(.vertical, 18).frame(maxWidth: .infinity)
                }.buttonStyle(LogoMatchedButtonStyle()).padding(.horizontal, 30).padding(.bottom, 40)
            }
        )
    }
}

struct RoomCard: View {
    let room: SavedRoom; var onTap: () -> Void; var onDelete: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 15) {
                ZStack {
                    Circle().fill(room.category.color.opacity(0.2)).frame(width: 44, height: 44)
                    Image(systemName: room.category.iconName).foregroundColor(room.category.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.name).font(.headline).foregroundColor(.white)
                    Text("\(Int(room.volume)) ft³").font(.subheadline).foregroundColor(.gray)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.subheadline).foregroundColor(.white.opacity(0.3))
            }
            .padding(16).background(.ultraThinMaterial).cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
        .contextMenu { Button(role: .destructive, action: onDelete) { Label("Delete Room", systemImage: "trash") } }
    }
}

// --- VIEW 3: SCANNING OVERLAY ---
struct ScanningOverlay: View {
    let activeRoomName: String?
    let people: Int
    let volume: Double
    let isVolumeLocked: Bool
    var onAnalyze: () -> Void
    var onCancel: () -> Void
    @State private var isBreathing = false
    
    var body: some View {
        ZStack {
            VStack {
                // Advanced visionOS style HUD header
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.title3.weight(.bold)).foregroundColor(.white).padding(12).background(.ultraThinMaterial).clipShape(Circle())
                    }
                    Spacer()
                    if let name = activeRoomName {
                        Text(name.uppercased()).font(.system(.subheadline)).bold().tracking(2).foregroundColor(.white).padding(.horizontal, 20).padding(.vertical, 10).background(.ultraThinMaterial).cornerRadius(20)
                    }
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }.padding(.top, 60).padding(.horizontal, 20)
                
                HStack(spacing: 15) {
                    StatusBadge(icon: "person.fill", label: "DETECTING: \(people)")
                    StatusBadge(icon: isVolumeLocked ? "lock.fill" : "cube.transparent", label: "\(Int(volume)) FT³").foregroundColor(isVolumeLocked ? .green : .white)
                }.padding(.top, 15)
                
                Spacer()
                Image(systemName: "viewfinder").font(.system(size: 100, weight: .ultraLight))
                    .foregroundColor(isVolumeLocked ? .green.opacity(0.8) : .white.opacity(0.8))
                    .scaleEffect(isBreathing ? 1.05 : 0.95)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isBreathing)
                    .onAppear { isBreathing = true }
                Spacer()
                
                Button(action: onAnalyze) {
                    Text("Analyze Environment").font(.system(.headline)).fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 20)
                }.buttonStyle(LogoMatchedButtonStyle()).padding(30)
            }
        }
    }
}

// --- VIEW 4: ANALYZING VIEW (Anticipation Builder) ---
struct AnalyzingView: View {
    @State private var isSpinning = false
    @State private var dotScale: CGFloat = 0.5
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.5).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 40) {
                ZStack {
                    // Outer spinning rings
                    Circle().stroke(LinearGradient(colors: [.cyan, .clear], startPoint: .top, endPoint: .bottom), lineWidth: 4)
                        .frame(width: 120, height: 120).rotationEffect(.degrees(isSpinning ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                    
                    Circle().stroke(LinearGradient(colors: [.purple, .clear], startPoint: .bottom, endPoint: .top), lineWidth: 4)
                        .frame(width: 100, height: 100).rotationEffect(.degrees(isSpinning ? -360 : 0))
                        .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isSpinning)
                    
                    // Core processor
                    Image(systemName: "cpu").font(.system(size: 40)).foregroundColor(.white)
                        .scaleEffect(dotScale).animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: dotScale)
                }
                
                Text("Synthesizing Data...")
                    .font(.system(.headline, design: .default)).tracking(4).foregroundColor(.white.opacity(0.8))
            }
        }
        .onAppear {
            isSpinning = true
            dotScale = 1.0
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

// --- VIEW 5: RESULTS CARD ---
struct ResultsView: View {
    let targetTempF: Double?
    let outdoorTempF: Double?
    let humidity: Int?
    let people: Int
    let volume: Double
    let city: String
    
    @Binding var isCelsius: Bool
    let isEcoMode: Bool
    @Binding var comfortOffset: Double
    let activeRoom: SavedRoom?
    
    var onSaveRoom: (String, RoomCategory) -> Void
    var onRetake: () -> Void
    var onHome: () -> Void
    
    @State private var showingSaveAlert = false
    @State private var newRoomName = ""
    @State private var selectedCategory: RoomCategory = .home
    
    // Dynamic Color Logic based on Temperature
    var auraColor: Color {
        guard let f = targetTempF else { return .cyan }
        if isEcoMode { return .green }
        if f >= 74 { return .orange } // Warm
        if f <= 69 { return .cyan }   // Cool
        return .blue // Perfect neutral
    }
    
    var displayTemp: String {
        guard let f = targetTempF else { return "--" }
        let val = isCelsius ? (f - 32) * 5/9 : f
        return String(format: "%.1f", val)
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activeRoom?.name.uppercased() ?? "NEW SCAN").font(.system(size: 12, weight: .black)).tracking(2).foregroundColor(.gray)
                            Text(city.uppercased()).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        }
                        Spacer()
                        Image(systemName: isEcoMode ? "leaf.fill" : "sparkles").font(.title2).foregroundColor(auraColor)
                    }
                    Divider().background(Color.white.opacity(0.2))
                    
                    HStack(alignment: .top) {
                        Spacer()
                        // ODOMETER TEXT EFFECT (iOS 16+ Magic)
                        Text(displayTemp)
                            .font(.system(size: 96, weight: .thin))
                            .contentTransition(.numericText()) // Rolls the numbers!
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: displayTemp)
                            .foregroundColor(.white)
                            .shadow(color: auraColor.opacity(0.6), radius: 20)
                        
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation { isCelsius.toggle() }
                        }) {
                            Text(isCelsius ? "°C" : "°F").font(.system(size: 18, weight: .bold)).foregroundColor(.white).padding(10).background(.ultraThinMaterial).clipShape(Circle())
                        }.offset(y: 20)
                        Spacer()
                    }
                    
                    Text(isEcoMode ? "ECO-OPTIMIZED SETTING" : "COMFORT-OPTIMIZED SETTING")
                        .font(.system(size: 10, weight: .black)).tracking(2).foregroundColor(auraColor)
                    
                    HStack(spacing: 15) {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            comfortOffset -= 0.5
                        }) {
                            HStack { Image(systemName: "snowflake").font(.caption); Text("Cooler").font(.system(size: 12, weight: .bold)) }
                            .padding(.horizontal, 20).padding(.vertical, 12).background(.ultraThinMaterial).cornerRadius(30).foregroundColor(.cyan)
                        }
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            comfortOffset += 0.5
                        }) {
                            HStack { Image(systemName: "flame.fill").font(.caption); Text("Warmer").font(.system(size: 12, weight: .bold)) }
                            .padding(.horizontal, 20).padding(.vertical, 12).background(.ultraThinMaterial).cornerRadius(30).foregroundColor(.orange)
                        }
                    }.padding(.bottom, 5)
                    
                    HStack(spacing: 12) {
                        DetailGridItem(title: "OUTDOOR", value: outdoorTempF != nil ? "\(Int(outdoorTempF!))°" : "--")
                        DetailGridItem(title: "HUMIDITY", value: humidity != nil ? "\(humidity!)%" : "--")
                        DetailGridItem(title: "OCCUPANTS", value: "\(people)")
                    }
                }
                .padding(30).background(.ultraThinMaterial).cornerRadius(40)
                .overlay(RoundedRectangle(cornerRadius: 40).stroke(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
                .padding(.horizontal, 20).shadow(color: auraColor.opacity(0.3), radius: 40, x: 0, y: 20) // Dynamic shadow!
                
                Spacer().frame(height: 35)
                
                HStack(spacing: 20) {
                    Spacer()
                    Button(action: onHome) { Image(systemName: "house.fill").font(.title2).foregroundColor(.white) }
                        .buttonStyle(MorphingActionButtonStyle(isPrimary: false, color: auraColor))
                    
                    Button(action: onRetake) { Image(systemName: "arrow.counterclockwise").font(.title).foregroundColor(.white) }
                        .buttonStyle(MorphingActionButtonStyle(isPrimary: true, color: auraColor))
                    
                    if activeRoom == nil {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation { showingSaveAlert = true }
                        }) { Image(systemName: "bookmark.fill").font(.title2).foregroundColor(.white) }
                        .buttonStyle(MorphingActionButtonStyle(isPrimary: false, color: auraColor))
                    } else { Color.clear.frame(width: 64, height: 64) }
                    Spacer()
                }.padding(.bottom, 50)
            }
            
            // --- CUSTOM CATEGORY SAVE MODAL ---
            if showingSaveAlert {
                Color.black.opacity(0.6).edgesIgnoringSafeArea(.all).onTapGesture { withAnimation { showingSaveAlert = false } }
                
                VStack(spacing: 25) {
                    Text("Save Zone").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                    TextField("Room Name (e.g., Living Room)", text: $newRoomName).padding().background(Color.white.opacity(0.1)).cornerRadius(15).foregroundColor(.white).accentColor(.cyan)
                    
                    HStack(spacing: 12) {
                        ForEach(RoomCategory.allCases, id: \.self) { category in
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                withAnimation { selectedCategory = category }
                            }) {
                                VStack(spacing: 10) {
                                    Image(systemName: category.iconName).font(.title2)
                                    Text(category.rawValue).font(.caption).fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(selectedCategory == category ? category.color.opacity(0.3) : Color.white.opacity(0.05))
                                .foregroundColor(selectedCategory == category ? category.color : .gray).cornerRadius(15)
                                .overlay(RoundedRectangle(cornerRadius: 15).stroke(selectedCategory == category ? category.color : Color.clear, lineWidth: 2))
                            }
                        }
                    }
                    
                    HStack(spacing: 15) {
                        Button(action: { withAnimation { showingSaveAlert = false } }) {
                            Text("Cancel").fontWeight(.bold).frame(maxWidth: .infinity).padding().background(Color.white.opacity(0.1)).cornerRadius(15).foregroundColor(.white)
                        }
                        Button(action: {
                            if !newRoomName.isEmpty {
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                onSaveRoom(newRoomName, selectedCategory)
                                withAnimation { showingSaveAlert = false }
                            }
                        }) { Text("Save").fontWeight(.bold).frame(maxWidth: .infinity).padding().background(selectedCategory.color).cornerRadius(15).foregroundColor(.white) }
                    }
                }
                .padding(30).background(.ultraThinMaterial).cornerRadius(35)
                .overlay(RoundedRectangle(cornerRadius: 35).stroke(Color.white.opacity(0.2), lineWidth: 1.5))
                .padding(.horizontal, 25).shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15).transition(.scale.combined(with: .opacity)).zIndex(100)
            }
        }
    }
}

// --- HELPER COMPONENTS ---
struct DetailGridItem: View {
    let title: String, value: String
    var body: some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 22, weight: .bold)).foregroundColor(.white)
            Text(title).font(.system(size: 9, weight: .black)).foregroundColor(.gray).tracking(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 15).background(Color.black.opacity(0.15)).cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct StatusBadge: View {
    let icon: String, label: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(.cyan).font(.system(size: 12, weight: .bold))
            Text(label).font(.system(size: 11, weight: .black)).tracking(1).foregroundColor(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).background(.ultraThinMaterial).cornerRadius(30)
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.white.opacity(0.3), lineWidth: 1))
    }
}

struct LogoMatchedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(
                Group {
                    if configuration.isPressed { Rectangle().fill(.ultraThinMaterial) }
                    else { LinearGradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).stroke(LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .shadow(color: configuration.isPressed ? .clear : Color.blue.opacity(0.4), radius: 15, x: 0, y: 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct MorphingActionButtonStyle: ButtonStyle {
    var isPrimary: Bool
    var color: Color // Dynamically matches the temperature glow
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: configuration.isPressed ? 90 : 64, height: 64)
            .background(
                Group {
                    if isPrimary { LinearGradient(colors: [color.opacity(0.8), color.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                    else { Rectangle().fill(.ultraThinMaterial) }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 32))
            .overlay(RoundedRectangle(cornerRadius: 32).stroke(LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .shadow(color: isPrimary ? color.opacity(0.5) : .black.opacity(0.2), radius: configuration.isPressed ? 2 : 15, x: 0, y: configuration.isPressed ? 1 : 8)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.5, blendDuration: 0.2), value: configuration.isPressed)
    }
}

// --- MANAGERS (WEATHER & AR) ---
class WeatherManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var outdoorTemp: Double? = nil
    @Published var humidity: Int? = nil
    @Published var city: String = "Locating..."
    private let locationManager = CLLocationManager()
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    
    func requestLocation() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .restricted, .denied: city = "GPS Denied"; fetchWeather(lat: 43.5978, lon: -84.7675)
        case .authorizedAlways, .authorizedWhenInUse: locationManager.startUpdatingLocation()
        @unknown default: break
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            locationManager.startUpdatingLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        locationManager.stopUpdatingLocation()
        fetchWeather(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            if let name = placemarks?.first?.locality { DispatchQueue.main.async { self.city = name } }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.city = "Loc Error"; self.fetchWeather(lat: 43.5978, lon: -84.7675) }
    }
    func fetchWeather(lat: Double, lon: Double) {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m&temperature_unit=fahrenheit"
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            if error != nil { return }
            guard let data = data else { return }
            if let result = try? JSONDecoder().decode(WeatherResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.outdoorTemp = result.current.temperature_2m
                    self.humidity = result.current.relative_humidity_2m
                }
            }
        }.resume()
    }
}

struct WeatherResponse: Codable { struct Current: Codable { let temperature_2m: Double; let relative_humidity_2m: Int }; let current: Current }

class ARManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published var detectedPeople: Int = 0
    @Published var estimatedDistance: Float = 3.0
    var arView: ARView?
    
    func pauseSession() { arView?.session.pause() }
    func resumeSession() {
        guard let config = arView?.session.configuration else { return }
        arView?.session.run(config)
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let pixelBuffer = frame.capturedImage as CVPixelBuffer? else { return }
        let request = VNDetectHumanRectanglesRequest { [weak self] request, _ in
            if let res = request.results as? [VNDetectedObjectObservation] {
                DispatchQueue.main.async { self?.detectedPeople = res.count }
            }
        }
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        if let view = arView {
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            if let hit = view.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first {
                DispatchQueue.main.async { self.estimatedDistance = length(hit.worldTransform.columns.3) }
            }
        }
    }
}

struct ARCameraView: UIViewRepresentable {
    @ObservedObject var arManager: ARManager
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration(); config.planeDetection = [.horizontal]
        arView.session.run(config); arView.session.delegate = arManager
        arView.debugOptions = [.showFeaturePoints]
        arManager.arView = arView
        return arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
