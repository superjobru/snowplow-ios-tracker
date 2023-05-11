//  Copyright (c) 2013-2023 Snowplow Analytics Ltd. All rights reserved.
//
//  This program is licensed to you under the Apache License Version 2.0,
//  and you may not use this file except in compliance with the Apache License
//  Version 2.0. You may obtain a copy of the Apache License Version 2.0 at
//  http://www.apache.org/licenses/LICENSE-2.0.
//
//  Unless required by applicable law or agreed to in writing,
//  software distributed under the Apache License Version 2.0 is distributed on
//  an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
//  express or implied. See the Apache License Version 2.0 for the specific
//  language governing permissions and limitations there under.

import Foundation

class ServiceProvider: NSObject, ServiceProviderProtocol {
    private(set) var namespace: String
    
    var isTrackerInitialized: Bool { return _tracker != nil }

    // Internal services
    private var _subject: Subject?
    var subject: Subject {
        if let subject = _subject { return subject }
        let subject = makeSubject()
        _subject = subject
        return subject
    }

    private var _emitter: Emitter?
    var emitter: Emitter {
        if let emitter = _emitter { return emitter }
        let emitter = makeEmitter()
        _emitter = emitter
        return emitter
    }

    private var _tracker: Tracker?
    var tracker: Tracker {
        if let tracker = _tracker { return tracker }
        let tracker = makeTracker()
        _tracker = tracker
        return tracker
    }

    // Controllers

    private var _trackerController: TrackerControllerImpl?
    var trackerController: TrackerControllerImpl {
        if let controller = _trackerController { return controller }
        let trackerController = makeTrackerController()
        _trackerController = trackerController
        return trackerController
    }

    private var _sessionController: SessionControllerImpl?
    var sessionController: SessionControllerImpl {
        if let controller = _sessionController { return controller }
        let sessionController = makeSessionController()
        _sessionController = sessionController
        return sessionController
    }

    private var _emitterController: EmitterControllerImpl?
    var emitterController: EmitterControllerImpl {
        if let controller = _emitterController { return controller }
        let emitterController = makeEmitterController()
        _emitterController = emitterController
        return emitterController
    }

    private var _gdprController: GDPRControllerImpl?
    var gdprController: GDPRControllerImpl {
        if let controller = _gdprController { return controller }
        let gdprController = makeGDPRController()
        _gdprController = gdprController
        return gdprController
    }

    var globalContextsController: GlobalContextsControllerImpl {
        return GlobalContextsControllerImpl(serviceProvider: self)
    }

    private var _subjectController: SubjectControllerImpl?
    var subjectController: SubjectControllerImpl {
        if let controller = _subjectController { return controller }
        let subjectController = makeSubjectController()
        _subjectController = subjectController
        return subjectController
    }

    private var _networkController: NetworkControllerImpl?
    var networkController: NetworkControllerImpl {
        if let controller = _networkController { return controller }
        let networkController = makeNetworkController()
        _networkController = networkController
        return networkController
    }
    
    var pluginsController: PluginsControllerImpl {
        return PluginsControllerImpl(serviceProvider: self)
    }
    
    // Original configurations
    private(set) var pluginConfigurations: [PluginConfigurationProtocol] = []

    // Configuration updates
    private(set) var networkConfigurationUpdate = NetworkConfigurationUpdate()
    private(set) var trackerConfigurationUpdate = TrackerConfigurationUpdate()
    private(set) var emitterConfigurationUpdate = EmitterConfigurationUpdate()
    private(set) var subjectConfigurationUpdate = SubjectConfigurationUpdate()
    private(set) var sessionConfigurationUpdate = SessionConfigurationUpdate()
    private(set) var gdprConfigurationUpdate = GDPRConfigurationUpdate()
    
    // MARK: - Init

    init(namespace: String, network networkConfiguration: NetworkConfiguration, configurations: [ConfigurationProtocol]) {
        self.namespace = namespace
        super.init()
        
        networkConfigurationUpdate.sourceConfig = networkConfiguration
        processConfigurations(configurations)
        if trackerConfigurationUpdate.sourceConfig == nil {
            trackerConfigurationUpdate.sourceConfig = TrackerConfiguration()
        }
        let _ = tracker // Build tracker to initialize NotificationCenter receivers
    }

    func reset(configurations: [ConfigurationProtocol]) {
        stopServices()
        resetConfigurationUpdates()
        processConfigurations(configurations)
        resetServices()
        let _ = tracker
    }

    func shutdown() {
        tracker.pauseEventTracking()
        stopServices()
        resetServices()
        resetControllers()
        initializeConfigurationUpdates()
    }

    // MARK: - Private methods

    func processConfigurations(_ configurations: [ConfigurationProtocol]) {
        for configuration in configurations {
            if let configuration = configuration as? NetworkConfiguration {
                networkConfigurationUpdate.sourceConfig = configuration
            } else if let configuration = configuration as? TrackerConfiguration {
                trackerConfigurationUpdate.sourceConfig = configuration
            } else if let configuration = configuration as? SubjectConfiguration {
                subjectConfigurationUpdate.sourceConfig = configuration
            } else if let configuration = configuration as? SessionConfiguration {
                sessionConfigurationUpdate.sourceConfig = configuration
            } else if let configuration = configuration as? EmitterConfiguration {
                emitterConfigurationUpdate.sourceConfig = configuration
            } else if let configuration = configuration as? GDPRConfiguration {
                gdprConfigurationUpdate.sourceConfig = configuration
            } else if let configuration = configuration as? GlobalContextsConfiguration {
                for plugin in configuration.toPluginConfigurations() {
                    pluginConfigurations.append(plugin)
                }
            } else if let configuration = configuration as? PluginConfigurationProtocol {
                pluginConfigurations.append(configuration)
            }
        }
    }

    func stopServices() {
        emitter.pauseTimer()
    }

    func resetServices() {
        _emitter = nil
        _subject = nil
        _tracker = nil
    }

    func resetControllers() {
        _trackerController = nil
        _sessionController = nil
        _emitterController = nil
        _gdprController = nil
        _subjectController = nil
        _networkController = nil
    }

    func resetConfigurationUpdates() {
        // Don't reset networkConfiguration as it's needed in case it's not passed in the new configurations.
        // Set a default trackerConfiguration to reset to default if not passed.
        trackerConfigurationUpdate.sourceConfig = TrackerConfiguration()
        emitterConfigurationUpdate.sourceConfig = nil
        subjectConfigurationUpdate.sourceConfig = nil
        sessionConfigurationUpdate.sourceConfig = nil
        gdprConfigurationUpdate.sourceConfig = nil
    }

    func initializeConfigurationUpdates() {
        networkConfigurationUpdate = NetworkConfigurationUpdate()
        trackerConfigurationUpdate = TrackerConfigurationUpdate()
        emitterConfigurationUpdate = EmitterConfigurationUpdate()
        subjectConfigurationUpdate = SubjectConfigurationUpdate()
        sessionConfigurationUpdate = SessionConfigurationUpdate()
        gdprConfigurationUpdate = GDPRConfigurationUpdate()
    }

    // MARK: - Getters

    // MARK: - Factories

    //#pragma clang diagnostic push
    //#pragma clang diagnostic ignored "-Wdeprecated-declarations"

    func makeSubject() -> Subject {
        return Subject(
            platformContext: trackerConfigurationUpdate.platformContext,
            platformContextProperties: trackerConfigurationUpdate.platformContextProperties,
            geoLocationContext: trackerConfigurationUpdate.geoLocationContext,
            subjectConfiguration: subjectConfigurationUpdate)
    }

    func makeEmitter() -> Emitter {
        let networkConfig = networkConfigurationUpdate
        let emitterConfig = emitterConfigurationUpdate
        
        let builder = { (emitter: Emitter) in
            if let method = networkConfig.method { emitter.method = method }
            if let prtcl = networkConfig.protocol { emitter.protocol = prtcl }
            emitter.customPostPath = networkConfig.customPostPath
            emitter.requestHeaders = networkConfig.requestHeaders
            emitter.emitThreadPoolSize = emitterConfig.threadPoolSize
            emitter.byteLimitGet = emitterConfig.byteLimitGet
            emitter.byteLimitPost = emitterConfig.byteLimitPost
            emitter.serverAnonymisation = emitterConfig.serverAnonymisation
            emitter.emitRange = emitterConfig.emitRange
            emitter.bufferOption = emitterConfig.bufferOption
            emitter.eventStore = emitterConfig.eventStore
            emitter.callback = emitterConfig.requestCallback
            emitter.customRetryForStatusCodes = emitterConfig.customRetryForStatusCodes
        }

        let emitter: Emitter
        if let networkConnection = networkConfig.networkConnection {
            emitter = Emitter(networkConnection: networkConnection, builder: builder)
        } else {
            emitter = Emitter(urlEndpoint: networkConfig.endpoint!, builder: builder)
        }
        
        if emitterConfig.isPaused {
            emitter.pauseEmit()
        }
        return emitter
    }

    func makeTracker() -> Tracker {
        let emitter = self.emitter
        let subject = self.subject
        
        let trackerConfig = trackerConfigurationUpdate
        let sessionConfig = sessionConfigurationUpdate
        let gdprConfig = gdprConfigurationUpdate
        
        let tracker = Tracker(
            trackerNamespace: namespace,
            appId: trackerConfig.appId,
            emitter: emitter
        ) { tracker in
            if let suffix = trackerConfig.trackerVersionSuffix {
                tracker.trackerVersionSuffix = suffix
            }
            tracker.sessionContext = trackerConfig.sessionContext
            tracker.foregroundTimeout = sessionConfig.foregroundTimeoutInSeconds
            tracker.backgroundTimeout = sessionConfig.backgroundTimeoutInSeconds
            tracker.exceptionEvents = trackerConfig.exceptionAutotracking
            tracker.subject = subject
            tracker.base64Encoded = trackerConfig.base64Encoding
            tracker.logLevel = trackerConfig.logLevel
            tracker.loggerDelegate = trackerConfig.loggerDelegate
            tracker.devicePlatform = trackerConfig.devicePlatform
            tracker.applicationContext = trackerConfig.applicationContext
            tracker.deepLinkContext = trackerConfig.deepLinkContext
            tracker.screenContext = trackerConfig.screenContext
            tracker.autotrackScreenViews = trackerConfig.screenViewAutotracking
            tracker.lifecycleEvents = trackerConfig.lifecycleAutotracking
            tracker.installEvent = trackerConfig.installAutotracking
            tracker.trackerDiagnostic = trackerConfig.diagnosticAutotracking
            tracker.userAnonymisation = trackerConfig.userAnonymisation
            tracker.advertisingIdentifierRetriever = trackerConfig.advertisingIdentifierRetriever
            if gdprConfig.sourceConfig != nil {
                tracker.gdprContext = GDPRContext(
                    basis: gdprConfig.basisForProcessing,
                    documentId: gdprConfig.documentId,
                    documentVersion: gdprConfig.documentVersion,
                    documentDescription: gdprConfig.documentDescription)
            }

            for plugin in pluginConfigurations {
                tracker.addOrReplace(stateMachine: plugin.toStateMachine())
            }
        }
        
        if trackerConfigurationUpdate.isPaused {
            tracker.pauseEventTracking()
        }
        if let session = tracker.session {
            if sessionConfigurationUpdate.isPaused {
                session.stopChecker()
            }
            if let callback = sessionConfigurationUpdate.onSessionStateUpdate {
                session.onSessionStateUpdate = callback
            }
        }
        return tracker
    }

    func makeTrackerController() -> TrackerControllerImpl {
        return TrackerControllerImpl(serviceProvider: self)
    }

    func makeSessionController() -> SessionControllerImpl {
        return SessionControllerImpl(serviceProvider: self)
    }

    func makeEmitterController() -> EmitterControllerImpl {
        return EmitterControllerImpl(serviceProvider: self)
    }

    func makeGDPRController() -> GDPRControllerImpl {
        let controller = GDPRControllerImpl(serviceProvider: self)
        if let gdpr = tracker.gdprContext {
            controller.reset(basis: gdpr.basis, documentId: gdpr.documentId, documentVersion: gdpr.documentVersion, documentDescription: gdpr.documentDescription)
        }
        return controller
    }

    func makeSubjectController() -> SubjectControllerImpl {
        return SubjectControllerImpl(serviceProvider: self)
    }

    func makeNetworkController() -> NetworkControllerImpl {
        return NetworkControllerImpl(serviceProvider: self)
    }
    
    func addPlugin(plugin: PluginConfigurationProtocol) {
        removePlugin(identifier: plugin.identifier)
        pluginConfigurations.append(plugin)
        tracker.addOrReplace(stateMachine: plugin.toStateMachine())
    }

    func removePlugin(identifier: String) {
        pluginConfigurations = pluginConfigurations.filter { $0.identifier != identifier }
        tracker.remove(stateMachineIdentifier: identifier)
    }
}