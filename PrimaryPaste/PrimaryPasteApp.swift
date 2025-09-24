//
//  PrimaryPasteApp.swift
//  PrimaryPaste
//
//  A macOS application that brings Linux X11-style primary selection functionality to Mac.
//  Select text with your mouse, paste it anywhere with middle-click.
//
//  Created by Adam Fasulo on 9/24/25.
//

import SwiftUI
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - Main Application Setup
@main
struct PrimarySelectionApp: App {
    // Use an AppDelegate to manage the application lifecycle and setup our services.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We don't need a main window, so we use Settings scene to keep the app running.
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let selectionManager = PrimarySelectionManager()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "Primary Selection Emulation")
        }

        // Create the menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Start the core functionality
        selectionManager.start()
    }
}


// MARK: - Core Logic Manager
/**
 * PrimarySelectionManager handles the core functionality of primary selection emulation.
 * It monitors mouse events system-wide and manages a separate pasteboard for primary selection.
 */
class PrimarySelectionManager {

    private var eventTap: CFMachPort?

    /// Private pasteboard for storing primary selection, separate from system clipboard
    private let primaryPasteboard = NSPasteboard(name: .init("com.afasulo.PrimaryPaste.Pasteboard"))

    /// Prevents re-copying identical text selections
    private var lastCopiedText: String = ""

    /// Initializes the primary selection system by checking permissions and setting up event monitoring
    func start() {
        checkAndSetupPermissions()
    }

    /// Checks for accessibility permissions and sets up event monitoring or starts permission polling
    private func checkAndSetupPermissions() {
        let hasAccessibility = AXIsProcessTrustedWithOptions(nil)

        if hasAccessibility {
            setupEventTap()
        } else {
            // Prompt for permissions
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)

            // Start polling for permission changes
            startPermissionPolling()
        }
    }

    /// Polls for accessibility permission changes and automatically starts event monitoring when granted
    private func startPermissionPolling() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            let hasPermission = AXIsProcessTrustedWithOptions(nil)

            if hasPermission {
                timer.invalidate()
                self.setupEventTap()
            }
        }
    }

    /// Creates and configures the global event tap for monitoring mouse clicks
    private func setupEventTap() {
        // Define the events to listen for: Left Mouse Up and Middle Mouse Down.
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)

        // The callback function that will handle the events.
        let eventCallback: CGEventTapCallBack = { proxy, type, event, refcon in
            if let refcon = refcon {
                let manager = Unmanaged<PrimarySelectionManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handle(event: event, type: type)
            }
            return Unmanaged.passUnretained(event)
        }

        // Create the event tap.
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            return
        }

        // Add the event tap to the run loop to start listening.
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
    

    /// Handles mouse events and triggers appropriate primary selection actions
    /// - Parameters:
    ///   - event: The mouse event that occurred
    ///   - type: The type of mouse event (left up, middle down, etc.)
    private func handle(event: CGEvent, type: CGEventType) {
        switch type {
        case .leftMouseUp:
            // Use a slight delay to ensure the selection has been registered by the OS.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.copySelectedText()
            }
        case .otherMouseDown: // Middle mouse button
            self.pasteFromPrimary()
        default:
            break
        }
    }
    
    
    // MARK: - Core Features
    

    /// Copies the currently selected text to the primary pasteboard
    /// Only updates if the text has changed to avoid unnecessary operations
    private func copySelectedText() {
        guard let selectedText = AccessibilityUtils.getSelectedText(), !selectedText.isEmpty else {
            return
        }

        // Only update the pasteboard if the text has changed
        if selectedText != lastCopiedText {
            primaryPasteboard.clearContents()
            primaryPasteboard.setString(selectedText, forType: .string)
            lastCopiedText = selectedText
        }
    }

    /// Pastes text from the primary pasteboard to the currently focused element
    private func pasteFromPrimary() {
        guard let textToPaste = primaryPasteboard.string(forType: .string), !textToPaste.isEmpty else {
            return
        }
        AccessibilityUtils.paste(text: textToPaste)
    }
}



// MARK: - Accessibility Utilities
/**
 * AccessibilityUtils provides helper methods for interacting with macOS accessibility APIs.
 * These methods allow reading selected text and pasting text directly without using the system clipboard.
 */
struct AccessibilityUtils {

    /// Gets the currently focused UI element from the frontmost application
    /// - Returns: The focused AXUIElement, or nil if none is found
    private static func getFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        
        let error = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        if error == .success, let element = focusedElement {
            return (element as! AXUIElement)
        }
        return nil
    }
    
    /// Retrieves the currently selected text using Accessibility APIs
    /// - Returns: The selected text string, or nil if no text is selected or accessible
    static func getSelectedText() -> String? {
        guard let focusedElement = getFocusedElement() else {
            return nil
        }

        var selectedText: AnyObject?
        let error = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedText)

        if error == .success, let text = selectedText as? String {
            return text
        }
        return nil
    }
    
    /// Pastes the given text into the focused element by setting its selected text value
    /// This method bypasses the system clipboard entirely
    /// - Parameter text: The text to paste into the focused element
    static func paste(text: String) {
        guard let focusedElement = getFocusedElement() else { return }
        
        // This is more reliable than simulating Cmd+V as it doesn't use the main clipboard.
        AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }
}
