import Cocoa
import EventKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let eventStore = EKEventStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only app (no Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menubar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Upcoming") {
                button.image = image
            }
            button.title = "Upcoming"
        }
        
        // Request calendar access and build menu
        requestCalendarAccess()
    }
    
    func requestCalendarAccess() {
        eventStore.requestFullAccessToEvents { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("Calendar access granted")
                    self.updateMenu()
                } else {
                    print("Calendar access denied: \(error?.localizedDescription ?? "unknown error")")
                    self.showAccessDeniedMenu()
                }
            }
        }
    }
    
    func updateMenu() {
        let menu = NSMenu()
        
        // Get today's events
        let events = fetchTodayEvents()
        
        if events.isEmpty {
            let noEventsItem = NSMenuItem(title: "No events today", action: nil, keyEquivalent: "")
            noEventsItem.isEnabled = false
            menu.addItem(noEventsItem)
        } else {
            for event in events {
                let timeFormatter = DateFormatter()
                timeFormatter.timeStyle = .short
                
                let startTime = timeFormatter.string(from: event.startDate)
                let title = "\(startTime) - \(event.title ?? "Untitled")"
                
                let eventItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                
                // Check if event has a URL in its notes/description
                if let url = extractURL(from: event) {
                    eventItem.representedObject = url
                    eventItem.action = #selector(openEventURL(_:))
                    eventItem.target = self
                    eventItem.isEnabled = true
                } else {
                    eventItem.isEnabled = false
                }
                
                menu.addItem(eventItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        
        statusItem.menu = menu
    }
    
    func extractURL(from event: EKEvent) -> URL? {
        // Check event URL first
        if let url = event.url {
            return url
        }
        
        // Check notes for URLs
        guard let notes = event.notes else { return nil }
        
        // Use NSDataDetector to find URLs in the text
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: notes, options: [], range: NSRange(location: 0, length: notes.utf16.count))
        
        if let match = matches?.first, let range = Range(match.range, in: notes) {
            let urlString = String(notes[range])
            return URL(string: urlString)
        }
        
        return nil
    }
    
    @objc func openEventURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
    
    func showAccessDeniedMenu() {
        let menu = NSMenu()
        
        let deniedItem = NSMenuItem(title: "Calendar access denied", action: nil, keyEquivalent: "")
        deniedItem.isEnabled = false
        menu.addItem(deniedItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        
        statusItem.menu = menu
    }
    
    func fetchTodayEvents() -> [EKEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )
        
        let events = eventStore.events(matching: predicate)
        return events.sorted { $0.startDate < $1.startDate }
    }

}

// Manual "main"
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
