lib/
├── app/
│   ├── router/              # Application navigation and route definitions
│   ├── views/               # Shared application shells
│   └── widgets/             # Application-wide reusable widgets
│
├── core/
│   ├── constants/           # Shared constants and configuration values
│   ├── errors/              # Common exceptions and error messages
│   └── utils/               # Reusable helpers and formatters
│
└── features/
    ├── ai_task_generation/
    │   ├── models/          # Generated-task data structures
    │   ├── repositories/    # Task-generation data access
    │   ├── services/        # AI and Edge Function communication
    │   ├── viewmodels/      # Generation and preview state
    │   ├── views/           # Task-generation screens
    │   └── widgets/         # Reusable generation UI components
    │
    ├── authentication/
    │   ├── models/          # User session and authentication data
    │   ├── repositories/    # Authentication contracts and data access
    │   ├── services/        # External authentication services
    │   ├── viewmodels/      # Login and registration state
    │   ├── views/           # Login and registration screens
    │   └── widgets/         # Authentication form components
    │
    ├── dashboard/
    │   ├── models/          # Dashboard summary data
    │   ├── repositories/    # Dashboard data access
    │   ├── services/        # Dashboard aggregation services
    │   ├── viewmodels/      # Dashboard state and loading logic
    │   ├── views/           # Dashboard screens
    │   └── widgets/         # Dashboard cards and sections
    │
    ├── kanban/
    │   ├── models/          # Tasks, tags, priorities and activities
    │   ├── repositories/    # Kanban database operations
    │   ├── services/        # Kanban coordination services
    │   ├── utils/           # Kanban-specific helpers and colours
    │   ├── viewmodels/      # Board and archived-task state
    │   ├── views/           # Kanban board and archive screens
    │   └── widgets/         # Task cards, forms and detail components
    │
    ├── learning_integration/
    │   ├── models/          # Learning-resource data structures
    │   ├── repositories/    # Learning-resource data access
    │   ├── services/        # External learning-resource integrations
    │   ├── viewmodels/      # Resource and recommendation state
    │   ├── views/           # Learning-resource screens
    │   └── widgets/         # Resource cards and related components
    │
    ├── notifications/
    │   ├── models/          # Notification and preference data
    │   ├── repositories/    # Notification and device-token data access
    │   ├── services/        # Realtime and push-notification services
    │   ├── viewmodels/      # Notification list and preference state
    │   ├── views/           # Notification screens
    │   └── widgets/         # Notification tiles, filters and empty states
    │
    ├── profile/
    │   ├── models/          # Profile and account data
    │   ├── repositories/    # Profile data access
    │   ├── services/        # Profile image and account services
    │   ├── viewmodels/      # Profile editing and account state
    │   ├── views/           # Profile and account screens
    │   └── widgets/         # Avatar and profile form components
    │
    ├── projects/
    │   ├── models/          # Project data structures
    │   ├── repositories/    # Project database operations
    │   ├── services/        # Project coordination services
    │   ├── viewmodels/      # Project form and dashboard state
    │   ├── views/           # Project dashboard and creation screens
    │   └── widgets/         # Project cards and form components
    │
    └── task_monitoring/
        ├── models/          # Monitoring and stagnation data
        ├── repositories/    # Monitoring data access
        ├── services/        # Monitoring and scoring services
        ├── viewmodels/      # Monitoring dashboard state
        ├── views/           # Monitoring and analytics screens
        └── widgets/         # Stagnation indicators and monitoring cards
Folder Responsibilities
Folder	Responsibility
models	Defines data structures used by the feature.
repositories	Provides data-access contracts and implementations.
services	Communicates with external services or coordinates specialized operations.
viewmodels	Manages UI state, validation and feature workflows.
views	Contains complete application screens.
widgets	Contains smaller reusable UI components.
utils	Contains helpers that are specific to one feature.
core	Contains reusable code shared across multiple features.
app	Contains global routing, application shells and shared widgets.
