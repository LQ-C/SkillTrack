## Project Structure

SkillTrack follows a feature-based MVVM architecture.

```text
lib/
├── app/
│   ├── router/
│   ├── views/
│   └── widgets/
│
├── core/
│   ├── constants/
│   ├── errors/
│   └── utils/
│
└── features/
    ├── ai_task_generation/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    ├── authentication/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    ├── dashboard/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    ├── kanban/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── utils/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    ├── learning_integration/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    ├── notifications/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    ├── profile/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    ├── projects/
    │   ├── models/
    │   ├── repositories/
    │   ├── services/
    │   ├── viewmodels/
    │   ├── views/
    │   └── widgets/
    │
    └── task_monitoring/
        ├── models/
        ├── repositories/
        ├── services/
        ├── viewmodels/
        ├── views/
        └── widgets/
```

### Folder Responsibilities

| Folder | Responsibility |
|---|---|
| `app` | Global routing, application shells and shared widgets. |
| `core` | Common code shared by multiple features. |
| `models` | Data structures used by a feature. |
| `repositories` | Data-access contracts and implementations. |
| `services` | External communication and specialized operations. |
| `viewmodels` | UI state, validation and feature workflows. |
| `views` | Complete application screens. |
| `widgets` | Smaller reusable interface components. |
| `utils` | Helpers that are specific to one feature. |
