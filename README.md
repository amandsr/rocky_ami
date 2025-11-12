# rocky_ami

%% This is Mermaid code. Paste it in a GitHub README.md
graph TD
    %% Define the swimlanes
    subgraph GitHub Actions (Orchestrator)
        direction LR
        T(🚀 Start: Push to main) --> J1[Job 1: Build & CIS Check]
        J1 -- Triggers --> P
        G1 -- Passed --> J2[Job 2: Wiz Scan]
        G1 -- Failed --> F1(🛑 STOP: CIS Failed)
        J2 -- Triggers --> W
        G2 -- Passed --> J3[Job 3: Promote & Distribute]
        G2 -- Failed --> F2(🛑 STOP: Wiz Failed)
        J3 -- Triggers --> R
        R -- Notifies --> S(🔔 Notify Slack)
        S --> E(🎉 Success)
    end

    subgraph AWS (Packer Build Instance)
        direction TB
        P[Packer: Launch Instance] --> A[Run Ansible Playbooks]
        A --> O[Run OpenSCAP Scan]
        O --> G1{Gate 1: CIS OK?}
    end

    subgraph AWS (AMI Registry)
        direction TB
        G1 -- Creates --> AMI([AMI: pending-scan])
        R[Promote: Tag/Copy/Share] --> AMI2([AMI: approved])
    end

    subgraph Wiz Platform
        direction TB
        W[Wiz: Scan AMI] --> G2{Gate 2: CVEs OK?}
    end

    %% Style the gates
    style G1 fill:#f9f,stroke:#333,stroke-width:2px
    style G2 fill:#f9f,stroke:#333,stroke-width:2px
