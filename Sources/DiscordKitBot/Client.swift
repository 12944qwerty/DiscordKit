//
//  Client.swift
//  
//
//  Created by Vincent Kwok on 21/11/22.
//

import Foundation
import Logging
import DiscordKitCore

/// The main client class for bots to interact with Discord's API
public final class Client {
    // REST handler
    private var rest: DiscordREST?

    // MARK: Gateway vars
    fileprivate var gateway: RobustWebSocket?
    private var evtHandlerID: EventDispatch.HandlerIdentifier?

    // MARK: Application Command Handlers
    fileprivate var appCommandHandlers: [String: NewAppCommand.Handler] = [:]

    // MARK: Event publishers
    private let notificationCenter = NotificationCenter()
    public let ready: NCWrapper<()>
    public let messageCreate: NCWrapper<BotMessage>

    // MARK: Configuration Members
    public let intents: Intents

    // Logger
    private static let logger = Logger(label: "Client", level: nil)

    // MARK: Information about the bot
    /// The user object of the bot
    public fileprivate(set) var user: User?
    /// The application ID of the bot
    ///
    /// This is used for registering application commands, among other actions.
    public fileprivate(set) var applicationID: String?

    public init(intents: Intents = .unprivileged) {
        self.intents = intents
        // Override default config for bots
        DiscordKitConfig.default = .init(
            properties: .init(browser: DiscordKitConfig.libraryName, device: DiscordKitConfig.libraryName),
            intents: intents
        )

        // Init event wrappers
        ready = .init(.ready, notificationCenter: notificationCenter)
        messageCreate = .init(.messageCreate, notificationCenter: notificationCenter)
    }

    deinit {
        disconnect()
    }

    /// Login to the Discord API with a token
    ///
    /// Calling this function will cause a connection to the Gateway to be attempted.
    ///
    /// > Warning: Ensure this function is called _before_ any calls to the API are made,
    /// > and _after_ all event sinks have been registered. API calls made before this call
    /// > will fail, and no events will be received while the gateway is disconnected.
    public func login(token: String) {
        rest = .init(token: token)
        gateway = .init(token: token)
        evtHandlerID = gateway?.onEvent.addHandler { [weak self] data in
            self?.handleEvent(data)
        }
    }

    /// Disconnect from the gateway, undoes ``login(token:)``
    ///
    /// Request that the gateway connection be gracefully closed. Also destroys
    /// the REST hander. Following this call, none of the APIs would function. Subsequently,
    /// connection can be restored by calling ``login(token:)`` again.
    public func disconnect() {
        // Remove event listeners and gracefully disconnect from Gateway
        gateway?.close(code: .normalClosure)
        if let evtHandlerID = evtHandlerID { _ = gateway?.onEvent.removeHandler(handler: evtHandlerID) }
        // Clear member vars
        gateway = nil
        rest = nil
        applicationID = nil
        user = nil
    }
}

// Gateway API
extension Client {
    public var isReady: Bool { gateway?.sessionOpen == true }

    /// Invoke the handler associated with the respective commands
    private func invokeCommandHandler(_ commandData: Interaction.Data.AppCommandData, id: Snowflake, token: String) {
        if let handler = appCommandHandlers[commandData.name] {
            Self.logger.trace("Invoking application handler", metadata: ["command.name": "\(commandData.name)"])
            Task {
                await handler(.init(
                    optionValues: commandData.options ?? [],
                    rest: rest!, token: token, interactionID: id
                ))
            }
        }
    }

    /// Handle a subset of gateway events
    private func handleEvent(_ data: GatewayIncoming.Data) {
        switch data {
        case .botReady(let readyEvt):
            let firstTime = applicationID == nil
            // Set several members with info about the bot
            applicationID = readyEvt.application.id
            user = readyEvt.user
            if firstTime {
                Self.logger.info("Bot client ready", metadata: [
                    "user.id": "\(readyEvt.user.id)",
                    "application.id": "\(readyEvt.application.id)"
                ])
                ready.emit()
            }
        case .messageCreate(let message):
            let botMessage = BotMessage(from: message)
            messageCreate.emit(value: botMessage)
        case .interaction(let interaction):
            Self.logger.trace("Received interaction", metadata: ["interaction.id": "\(interaction.id)"])
            if case .applicationCommand(let commandData) = interaction.data {
                invokeCommandHandler(commandData, id: interaction.id, token: interaction.token)
            }
        default:
            break
        }
    }
}

// MARK: - REST-related API
public extension Client {
    func sendMessage(_ content: String, channel: Snowflake, replyingTo: Snowflake? = nil) async throws -> Message {
        let reference = replyingTo != nil ? MessageReference(message_id: replyingTo) : nil
        return try await rest!.createChannelMsg(message: .init(content: content, message_reference: reference), id: channel)
    }

    // MARK: Interactions
    /// Register Application Commands with a result builder
    func registerApplicationCommands(
        guild: Snowflake? = nil, @AppCommandBuilder _ commands: () -> [NewAppCommand]
    ) async throws {
        try await registerApplicationCommands(guild: guild, commands())
    }
    /// Register Application Commands with the provided application command create structs
    func registerApplicationCommands(guild: Snowflake? = nil, _ commands: [NewAppCommand]) async throws {
        for command in commands {
            try await rest!.createCommand(command, applicationID: applicationID!, guildID: guild)
            appCommandHandlers[command.name] = command.handler
        }
    }
}
