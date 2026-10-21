/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    12_dw_facts.sql
   Purpose: 5 fact tables of the fact constellation, matching the UML physical
            model in docs/diagrams/03-dw-physical-uml.drawio.
   Target:  Microsoft SQL Server 2019+
   Depends: 11_dw_dimensions.sql must have run first.

   Fact                              Type                Grain
   --------------------------------  ------------------  -----------------------
   FactViewingSession                transaction         one row per
                                                         play.WatchSession
   FactSubscriptionMonthlySnapshot   periodic snapshot   one row per subscription
                                                         per month-end
   FactRevenue                       transaction         one row per bill.Payment
   FactTitleRating                   transaction         one row per play.Review
   FactCatalogAvailabilitySnapshot   periodic snapshot   one row per title x
                                                         country x month-end

   Modelling conventions
     - Surrogate INT IDENTITY primary key "<Fact>Key".
     - Every dimension key is NOT NULL and has a FOREIGN KEY to its dimension.
       Unresolved lookups point at the -1 Unknown member, never at NULL.
     - Role-playing dates (InvoiceDate / PaymentDate, SnapshotDate / SignupDate,
       AvailableFrom / AvailableUntil) each have their own foreign key to
       dw.DimDate.
     - The natural key of the source row (WatchSessionID, PaymentID, ReviewID)
       is UNIQUE, which is what the incremental delete-then-insert relies on.
       The snapshots are unique on their grain.
     - Flags that a report SUMs (IsCompletedFlag, IsBingeSession, ...) are
       TINYINT, not BIT, because SUM() does not accept BIT.
     - BatchID ties every row to the etl.LoadAudit run that wrote it.
   ============================================================================= */

USE HBOMaxDW;
GO

/* =============================================================================
   dw.FactViewingSession - what was watched, by whom, where, when and how well
   Measures: SecondsWatched (additive), MinutesWatched / HoursWatched (computed,
   additive), PercentComplete (non-additive - average it), IsCompletedFlag,
   SessionCount, BufferingEvents, IsBingeSession (additive).
   EpisodeID is 0 for a film or special (not an episode).
   ============================================================================= */
CREATE TABLE dw.FactViewingSession
(
    ViewingSessionKey  INT             NOT NULL IDENTITY(1,1),
    DateKey            INT             NOT NULL,
    TimeKey            INT             NOT NULL,
    ProfileKey         INT             NOT NULL,
    SubscriberKey      INT             NOT NULL,
    TitleKey           INT             NOT NULL,
    GenreKey           INT             NOT NULL,
    DeviceKey          INT             NOT NULL,
    GeographyKey       INT             NOT NULL,
    PlanKey            INT             NOT NULL,
    WatchSessionID     BIGINT          NOT NULL,
    EpisodeID          INT             NOT NULL CONSTRAINT DF_FVS_Episode DEFAULT (0),
    VideoQuality       VARCHAR(4)      NOT NULL,
    StartedAt          DATETIME2(0)    NOT NULL,
    EndedAt            DATETIME2(0)    NULL,
    SecondsWatched     INT             NOT NULL,
    MinutesWatched     AS CAST(SecondsWatched / 60.0   AS DECIMAL(12,2)) PERSISTED,
    HoursWatched       AS CAST(SecondsWatched / 3600.0 AS DECIMAL(12,4)) PERSISTED,
    PercentComplete    DECIMAL(5,2)    NOT NULL,
    IsCompletedFlag    TINYINT         NOT NULL,
    SessionCount       TINYINT         NOT NULL CONSTRAINT DF_FVS_SessionCount DEFAULT (1),
    BufferingEvents    SMALLINT        NOT NULL,
    IsBingeSession     TINYINT         NOT NULL,
    BatchID            UNIQUEIDENTIFIER NOT NULL,
    RowInsertedAt      DATETIME2(3)    NOT NULL CONSTRAINT DF_FVS_Ins DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_FactViewingSession   PRIMARY KEY (ViewingSessionKey),
    CONSTRAINT UQ_FVS_WatchSession     UNIQUE (WatchSessionID),
    CONSTRAINT FK_FVS_Date       FOREIGN KEY (DateKey)       REFERENCES dw.DimDate       (DateKey),
    CONSTRAINT FK_FVS_Time       FOREIGN KEY (TimeKey)       REFERENCES dw.DimTimeOfDay  (TimeKey),
    CONSTRAINT FK_FVS_Profile    FOREIGN KEY (ProfileKey)    REFERENCES dw.DimProfile    (ProfileKey),
    CONSTRAINT FK_FVS_Subscriber FOREIGN KEY (SubscriberKey) REFERENCES dw.DimSubscriber (SubscriberKey),
    CONSTRAINT FK_FVS_Title      FOREIGN KEY (TitleKey)      REFERENCES dw.DimTitle      (TitleKey),
    CONSTRAINT FK_FVS_Genre      FOREIGN KEY (GenreKey)      REFERENCES dw.DimGenre      (GenreKey),
    CONSTRAINT FK_FVS_Device     FOREIGN KEY (DeviceKey)     REFERENCES dw.DimDevice     (DeviceKey),
    CONSTRAINT FK_FVS_Geography  FOREIGN KEY (GeographyKey)  REFERENCES dw.DimGeography  (GeographyKey),
    CONSTRAINT FK_FVS_Plan       FOREIGN KEY (PlanKey)       REFERENCES dw.DimPlan       (PlanKey),
    CONSTRAINT CK_FVS_Pct        CHECK (PercentComplete BETWEEN 0 AND 100),
    CONSTRAINT CK_FVS_Flags      CHECK (IsCompletedFlag IN (0, 1) AND IsBingeSession IN (0, 1))
);
GO

/* =============================================================================
   dw.FactSubscriptionMonthlySnapshot - the state of every subscription at
   every month-end. Semi-additive: ActiveSubscriptionCount and
   MonthlyRecurringRevenue add up across subscriptions and plans, but NOT
   across months (take the last month or an average instead).
   ============================================================================= */
CREATE TABLE dw.FactSubscriptionMonthlySnapshot
(
    SubscriptionSnapshotKey  INT             NOT NULL IDENTITY(1,1),
    SnapshotDateKey          INT             NOT NULL,
    SubscriberKey            INT             NOT NULL,
    PlanKey                  INT             NOT NULL,
    GeographyKey             INT             NOT NULL,
    SignupDateKey            INT             NOT NULL,
    SubscriptionID           INT             NOT NULL,
    SubscriptionStatus       VARCHAR(12)     NOT NULL,
    BillingCycle             VARCHAR(8)      NOT NULL,
    AutoRenew                BIT             NOT NULL,
    SnapshotMonthKey         INT             NOT NULL,
    SignupCohortMonthKey     INT             NOT NULL,
    ActiveSubscriptionCount  TINYINT         NOT NULL,
    MonthlyRecurringRevenue  DECIMAL(12,2)   NOT NULL,
    TenureMonths             INT             NOT NULL,
    IsNewThisMonth           TINYINT         NOT NULL,
    IsChurnedThisMonth       TINYINT         NOT NULL,
    IsTrialing               TINYINT         NOT NULL,
    BatchID                  UNIQUEIDENTIFIER NOT NULL,
    RowInsertedAt            DATETIME2(3)    NOT NULL CONSTRAINT DF_FSMS_Ins DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_FactSubscriptionMonthlySnapshot PRIMARY KEY (SubscriptionSnapshotKey),
    CONSTRAINT UQ_FSMS_Grain       UNIQUE (SnapshotDateKey, SubscriptionID),
    CONSTRAINT FK_FSMS_SnapDate    FOREIGN KEY (SnapshotDateKey) REFERENCES dw.DimDate       (DateKey),
    CONSTRAINT FK_FSMS_Subscriber  FOREIGN KEY (SubscriberKey)   REFERENCES dw.DimSubscriber (SubscriberKey),
    CONSTRAINT FK_FSMS_Plan        FOREIGN KEY (PlanKey)         REFERENCES dw.DimPlan       (PlanKey),
    CONSTRAINT FK_FSMS_Geography   FOREIGN KEY (GeographyKey)    REFERENCES dw.DimGeography  (GeographyKey),
    CONSTRAINT FK_FSMS_SignupDate  FOREIGN KEY (SignupDateKey)   REFERENCES dw.DimDate       (DateKey),
    CONSTRAINT CK_FSMS_Mrr         CHECK (MonthlyRecurringRevenue >= 0)
);
GO

/* =============================================================================
   dw.FactRevenue - one row per payment attempt, with the invoice amounts
   allocated to it. NetRevenueAmount = PaidAmount - RefundedAmount.
   ============================================================================= */
CREATE TABLE dw.FactRevenue
(
    RevenueKey          INT             NOT NULL IDENTITY(1,1),
    InvoiceDateKey      INT             NOT NULL,
    PaymentDateKey      INT             NOT NULL,
    TimeKey             INT             NOT NULL,
    SubscriberKey       INT             NOT NULL,
    PlanKey             INT             NOT NULL,
    GeographyKey        INT             NOT NULL,
    PaymentMethodKey    INT             NOT NULL,
    PaymentID           INT             NOT NULL,
    InvoiceID           INT             NOT NULL,
    InvoiceNumber       VARCHAR(20)     NOT NULL,
    SubscriptionID      INT             NOT NULL,
    PaymentStatus       VARCHAR(10)     NOT NULL,
    InvoiceStatus       VARCHAR(14)     NOT NULL,
    CurrencyCode        CHAR(3)         NOT NULL,
    BillingPeriodStart  DATE            NULL,
    BillingPeriodEnd    DATE            NULL,
    SubtotalAmount      DECIMAL(12,2)   NOT NULL,
    DiscountAmount      DECIMAL(12,2)   NOT NULL,
    TaxAmount           DECIMAL(12,2)   NOT NULL,
    PaidAmount          DECIMAL(12,2)   NOT NULL,
    RefundedAmount      DECIMAL(12,2)   NOT NULL,
    NetRevenueAmount    AS CAST(PaidAmount - RefundedAmount AS DECIMAL(12,2)) PERSISTED,
    PaymentCount        TINYINT         NOT NULL,
    FailedPaymentCount  TINYINT         NOT NULL,
    DaysToPay           INT             NULL,
    BatchID             UNIQUEIDENTIFIER NOT NULL,
    RowInsertedAt       DATETIME2(3)    NOT NULL CONSTRAINT DF_FR_Ins DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_FactRevenue       PRIMARY KEY (RevenueKey),
    CONSTRAINT UQ_FR_Payment        UNIQUE (PaymentID),
    CONSTRAINT FK_FR_InvoiceDate    FOREIGN KEY (InvoiceDateKey)   REFERENCES dw.DimDate          (DateKey),
    CONSTRAINT FK_FR_PaymentDate    FOREIGN KEY (PaymentDateKey)   REFERENCES dw.DimDate          (DateKey),
    CONSTRAINT FK_FR_Time           FOREIGN KEY (TimeKey)          REFERENCES dw.DimTimeOfDay     (TimeKey),
    CONSTRAINT FK_FR_Subscriber     FOREIGN KEY (SubscriberKey)    REFERENCES dw.DimSubscriber    (SubscriberKey),
    CONSTRAINT FK_FR_Plan           FOREIGN KEY (PlanKey)          REFERENCES dw.DimPlan          (PlanKey),
    CONSTRAINT FK_FR_Geography      FOREIGN KEY (GeographyKey)     REFERENCES dw.DimGeography     (GeographyKey),
    CONSTRAINT FK_FR_PaymentMethod  FOREIGN KEY (PaymentMethodKey) REFERENCES dw.DimPaymentMethod (PaymentMethodKey),
    CONSTRAINT CK_FR_Amounts        CHECK (PaidAmount >= 0 AND RefundedAmount >= 0 AND RefundedAmount <= PaidAmount)
);
GO

/* =============================================================================
   dw.FactTitleRating - one row per review. RatingValue is non-additive
   (average it); ReviewCount, HelpfulVotes and the flags are additive.
   ============================================================================= */
CREATE TABLE dw.FactTitleRating
(
    TitleRatingKey  INT             NOT NULL IDENTITY(1,1),
    DateKey         INT             NOT NULL,
    TimeKey         INT             NOT NULL,
    TitleKey        INT             NOT NULL,
    GenreKey        INT             NOT NULL,
    ProfileKey      INT             NOT NULL,
    SubscriberKey   INT             NOT NULL,
    GeographyKey    INT             NOT NULL,
    ReviewID        INT             NOT NULL,
    CreatedAt       DATETIME2(0)    NOT NULL,
    UpdatedAt       DATETIME2(0)    NULL,
    RatingValue     TINYINT         NOT NULL,
    ReviewCount     TINYINT         NOT NULL CONSTRAINT DF_FTR_Count DEFAULT (1),
    HelpfulVotes    INT             NOT NULL,
    HasTextFlag     TINYINT         NOT NULL,
    IsFlaggedFlag   TINYINT         NOT NULL,
    ReviewLength    INT             NOT NULL,
    BatchID         UNIQUEIDENTIFIER NOT NULL,
    RowInsertedAt   DATETIME2(3)    NOT NULL CONSTRAINT DF_FTR_Ins DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_FactTitleRating   PRIMARY KEY (TitleRatingKey),
    CONSTRAINT UQ_FTR_Review        UNIQUE (ReviewID),
    CONSTRAINT FK_FTR_Date          FOREIGN KEY (DateKey)       REFERENCES dw.DimDate       (DateKey),
    CONSTRAINT FK_FTR_Time          FOREIGN KEY (TimeKey)       REFERENCES dw.DimTimeOfDay  (TimeKey),
    CONSTRAINT FK_FTR_Title         FOREIGN KEY (TitleKey)      REFERENCES dw.DimTitle      (TitleKey),
    CONSTRAINT FK_FTR_Genre         FOREIGN KEY (GenreKey)      REFERENCES dw.DimGenre      (GenreKey),
    CONSTRAINT FK_FTR_Profile       FOREIGN KEY (ProfileKey)    REFERENCES dw.DimProfile    (ProfileKey),
    CONSTRAINT FK_FTR_Subscriber    FOREIGN KEY (SubscriberKey) REFERENCES dw.DimSubscriber (SubscriberKey),
    CONSTRAINT FK_FTR_Geography     FOREIGN KEY (GeographyKey)  REFERENCES dw.DimGeography  (GeographyKey),
    CONSTRAINT CK_FTR_Rating        CHECK (RatingValue BETWEEN 1 AND 10)
);
GO

/* =============================================================================
   dw.FactCatalogAvailabilitySnapshot - which title was licensed in which
   country at every month-end. Semi-additive like the subscription snapshot.
   AvailableUntilDateKey = -1 means an open-ended licence.
   ============================================================================= */
CREATE TABLE dw.FactCatalogAvailabilitySnapshot
(
    CatalogSnapshotKey     INT             NOT NULL IDENTITY(1,1),
    SnapshotDateKey        INT             NOT NULL,
    TitleKey               INT             NOT NULL,
    GenreKey               INT             NOT NULL,
    GeographyKey           INT             NOT NULL,
    AvailableFromDateKey   INT             NOT NULL,
    AvailableUntilDateKey  INT             NOT NULL,
    LicenseType            VARCHAR(14)     NOT NULL,
    SnapshotMonthKey       INT             NOT NULL,
    TitlesAvailableCount   TINYINT         NOT NULL,
    DaysInCatalog          INT             NOT NULL,
    DaysUntilExpiry        INT             NULL,
    IsExpiringSoon         TINYINT         NOT NULL,
    BatchID                UNIQUEIDENTIFIER NOT NULL,
    RowInsertedAt          DATETIME2(3)    NOT NULL CONSTRAINT DF_FCAS_Ins DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_FactCatalogAvailabilitySnapshot PRIMARY KEY (CatalogSnapshotKey),
    CONSTRAINT UQ_FCAS_Grain       UNIQUE (SnapshotDateKey, TitleKey, GeographyKey),
    CONSTRAINT FK_FCAS_SnapDate    FOREIGN KEY (SnapshotDateKey)       REFERENCES dw.DimDate      (DateKey),
    CONSTRAINT FK_FCAS_Title       FOREIGN KEY (TitleKey)              REFERENCES dw.DimTitle     (TitleKey),
    CONSTRAINT FK_FCAS_Genre       FOREIGN KEY (GenreKey)              REFERENCES dw.DimGenre     (GenreKey),
    CONSTRAINT FK_FCAS_Geography   FOREIGN KEY (GeographyKey)          REFERENCES dw.DimGeography (GeographyKey),
    CONSTRAINT FK_FCAS_FromDate    FOREIGN KEY (AvailableFromDateKey)  REFERENCES dw.DimDate      (DateKey),
    CONSTRAINT FK_FCAS_UntilDate   FOREIGN KEY (AvailableUntilDateKey) REFERENCES dw.DimDate      (DateKey)
);
GO

/* =============================================================================
   Indexes - the fact foreign keys that the analytic views group and filter on.
   ============================================================================= */
CREATE INDEX IX_FVS_Date        ON dw.FactViewingSession (DateKey) INCLUDE (SecondsWatched, GeographyKey);
CREATE INDEX IX_FVS_Title       ON dw.FactViewingSession (TitleKey);
CREATE INDEX IX_FVS_Genre_Time  ON dw.FactViewingSession (GenreKey, TimeKey);
CREATE INDEX IX_FVS_Device      ON dw.FactViewingSession (DeviceKey);
CREATE INDEX IX_FVS_Batch       ON dw.FactViewingSession (BatchID);
CREATE INDEX IX_FSMS_Month      ON dw.FactSubscriptionMonthlySnapshot (SnapshotMonthKey, PlanKey);
CREATE INDEX IX_FSMS_Cohort     ON dw.FactSubscriptionMonthlySnapshot (SignupCohortMonthKey);
CREATE INDEX IX_FR_PaymentDate  ON dw.FactRevenue (PaymentDateKey, PlanKey);
CREATE INDEX IX_FR_Invoice      ON dw.FactRevenue (InvoiceID);
CREATE INDEX IX_FR_Batch        ON dw.FactRevenue (BatchID);
CREATE INDEX IX_FTR_Title       ON dw.FactTitleRating (TitleKey);
CREATE INDEX IX_FTR_Batch       ON dw.FactTitleRating (BatchID);
CREATE INDEX IX_FCAS_Month      ON dw.FactCatalogAvailabilitySnapshot (SnapshotMonthKey, TitleKey);
GO

PRINT 'HBOMaxDW: 5 fact tables created.';
GO
