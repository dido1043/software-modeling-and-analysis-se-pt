/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    13_etl_staging.sql
   Purpose: The etl schema - run control (LoadAudit, LoadWatermark) and the
            staging tables used by the load procedures in 14_etl_procedures.sql.
   Target:  Microsoft SQL Server 2019+
   Depends: 10_create_dw_database.sql must have run first.

   Table                 Role
   --------------------  -------------------------------------------------------
   etl.LoadAudit         one row per procedure execution: what ran, when, how
                         many rows were read / inserted / updated / attached to
                         an Unknown member, and the error if it failed
   etl.LoadWatermark     high-water mark of each incremental fact load
   etl.StgPlan           acct.Plan with derived PriceBand / AdvertisingLabel
   etl.StgSubscriber     acct.Subscriber denormalised with country, language,
                         age band and tenure band
   etl.StgWatchSession   load window of play.WatchSession with business keys
                         pre-resolved (subscriber, primary genre, plan in force)
   etl.StgPayment        load window of bill.Payment joined to its invoice,
                         with the allocation ratio of the invoice to the payment
   etl.StgReview         load window of play.Review with derived text flags

   The staging tables are TRUNCATEd by their procedure on every run; they only
   hold the rows of the current load window.
   ============================================================================= */

USE HBOMaxDW;
GO

/* =============================================================================
   etl.LoadAudit
   ============================================================================= */
CREATE TABLE etl.LoadAudit
(
    LoadAuditID      BIGINT           NOT NULL IDENTITY(1,1),
    BatchID          UNIQUEIDENTIFIER NOT NULL,
    PackageName      SYSNAME          NOT NULL,
    ProcedureName    SYSNAME          NOT NULL,
    TargetObject     SYSNAME          NULL,
    LoadType         VARCHAR(12)      NOT NULL,
    StartedAt        DATETIME2(3)     NOT NULL CONSTRAINT DF_LoadAudit_Started DEFAULT (SYSUTCDATETIME()),
    CompletedAt      DATETIME2(3)     NULL,
    DurationSeconds  AS DATEDIFF(SECOND, StartedAt, CompletedAt) PERSISTED,
    RowsRead         INT              NOT NULL CONSTRAINT DF_LoadAudit_Read     DEFAULT (0),
    RowsInserted     INT              NOT NULL CONSTRAINT DF_LoadAudit_Inserted DEFAULT (0),
    RowsUpdated      INT              NOT NULL CONSTRAINT DF_LoadAudit_Updated  DEFAULT (0),
    RowsRejected     INT              NOT NULL CONSTRAINT DF_LoadAudit_Rejected DEFAULT (0),
    LoadStatus       VARCHAR(10)      NOT NULL CONSTRAINT DF_LoadAudit_Status   DEFAULT ('Running'),
    ErrorNumber      INT              NULL,
    ErrorLine        INT              NULL,
    ErrorMessage     NVARCHAR(2048)   NULL,
    ExecutedBy       NVARCHAR(128)    NOT NULL CONSTRAINT DF_LoadAudit_By   DEFAULT (SUSER_SNAME()),
    HostName         NVARCHAR(128)    NOT NULL CONSTRAINT DF_LoadAudit_Host DEFAULT (ISNULL(HOST_NAME(), N'(unknown)')),
    CONSTRAINT PK_LoadAudit         PRIMARY KEY (LoadAuditID),
    CONSTRAINT CK_LoadAudit_Type    CHECK (LoadType IN ('Full', 'Incremental', 'SCD1', 'SCD2', 'Snapshot', 'Orchestrator')),
    CONSTRAINT CK_LoadAudit_Status  CHECK (LoadStatus IN ('Running', 'Succeeded', 'Failed'))
);
GO
CREATE INDEX IX_LoadAudit_Batch ON etl.LoadAudit (BatchID, LoadAuditID);
GO

/* =============================================================================
   etl.LoadWatermark - one row per incremental fact
   ============================================================================= */
CREATE TABLE etl.LoadWatermark
(
    WatermarkID         INT           NOT NULL IDENTITY(1,1),
    SourceObject        SYSNAME       NOT NULL,
    TargetObject        SYSNAME       NOT NULL,
    WatermarkColumn     SYSNAME       NOT NULL,
    LastLoadedDateTime  DATETIME2(3)  NULL,
    LastLoadedKey       BIGINT        NULL,
    LookbackMinutes     INT           NOT NULL CONSTRAINT DF_Watermark_Lookback DEFAULT (4320),
    LastLoadAt          DATETIME2(3)  NULL,
    RowsLastLoad        INT           NOT NULL CONSTRAINT DF_Watermark_Rows DEFAULT (0),
    RowInsertedAt       DATETIME2(3)  NOT NULL CONSTRAINT DF_Watermark_Ins DEFAULT (SYSUTCDATETIME()),
    RowUpdatedAt        DATETIME2(3)  NOT NULL CONSTRAINT DF_Watermark_Upd DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_LoadWatermark        PRIMARY KEY (WatermarkID),
    CONSTRAINT UQ_LoadWatermark_Target UNIQUE (TargetObject),
    CONSTRAINT CK_LoadWatermark_Look   CHECK (LookbackMinutes >= 0)
);
GO

/* LastLoadedDateTime = NULL means "never loaded": the first run is a full load.
   The 3-day (4320 minute) lookback re-reads late-arriving and changed rows. */
INSERT INTO etl.LoadWatermark (SourceObject, TargetObject, WatermarkColumn, LookbackMinutes)
VALUES (N'HBOMaxOLTP.play.WatchSession', N'dw.FactViewingSession', N'StartedAt',            4320),
       (N'HBOMaxOLTP.bill.Payment',      N'dw.FactRevenue',        N'PaidAt',               4320),
       (N'HBOMaxOLTP.play.Review',       N'dw.FactTitleRating',    N'CreatedAt/UpdatedAt',  4320);
GO

/* =============================================================================
   Staging tables
   ============================================================================= */
CREATE TABLE etl.StgPlan
(
    PlanID                INT            NOT NULL,
    PlanCode              VARCHAR(20)    NOT NULL,
    PlanName              NVARCHAR(60)   NOT NULL,
    MonthlyPrice          DECIMAL(8,2)   NOT NULL,
    AnnualPrice           DECIMAL(8,2)   NULL,
    CurrencyCode          CHAR(3)        NOT NULL,
    PriceBand             VARCHAR(20)    NOT NULL,
    MaxConcurrentStreams  TINYINT        NOT NULL,
    MaxVideoQuality       VARCHAR(4)     NOT NULL,
    MaxProfiles           TINYINT        NOT NULL,
    AllowsDownloads       BIT            NOT NULL,
    HasAdvertising        BIT            NOT NULL,
    AdvertisingLabel      VARCHAR(12)    NOT NULL,
    IsActive              BIT            NOT NULL,
    SourceEffectiveFrom   DATE           NOT NULL,
    CONSTRAINT PK_StgPlan PRIMARY KEY (PlanID)
);
GO

CREATE TABLE etl.StgSubscriber
(
    SubscriberID           INT            NOT NULL,
    Email                  NVARCHAR(256)  NOT NULL,
    FirstName              NVARCHAR(60)   NOT NULL,
    LastName               NVARCHAR(60)   NOT NULL,
    DateOfBirth            DATE           NOT NULL,
    Gender                 CHAR(1)        NULL,
    GenderLabel            NVARCHAR(12)   NOT NULL,
    AgeYears               SMALLINT       NULL,
    AgeBand                VARCHAR(10)    NOT NULL,
    CountryID              INT            NOT NULL,
    CountryName            NVARCHAR(100)  NOT NULL,
    IsoAlpha2              CHAR(2)        NOT NULL,
    RegionName             NVARCHAR(30)   NOT NULL,
    PreferredLanguageName  NVARCHAR(60)   NOT NULL,
    AccountStatus          VARCHAR(12)    NOT NULL,
    MarketingOptIn         BIT            NOT NULL,
    RegisteredAt           DATETIME2(0)   NOT NULL,
    RegistrationDateKey    INT            NOT NULL,
    SignupCohortMonthKey   INT            NOT NULL,
    LastLoginAt            DATETIME2(0)   NULL,
    TenureMonths           INT            NOT NULL,
    TenureBand             VARCHAR(14)    NOT NULL,
    CONSTRAINT PK_StgSubscriber PRIMARY KEY (SubscriberID)
);
GO

CREATE TABLE etl.StgWatchSession
(
    WatchSessionID    BIGINT         NOT NULL,
    ProfileID         INT            NOT NULL,
    SubscriberID      INT            NOT NULL,
    TitleID           INT            NOT NULL,
    EpisodeID         INT            NULL,
    PrimaryGenreID    INT            NULL,
    DeviceID          INT            NOT NULL,
    CountryID         INT            NOT NULL,
    PlanID            INT            NULL,
    StartedAt         DATETIME2(0)   NOT NULL,
    EndedAt           DATETIME2(0)   NULL,
    SessionDate       DATE           NOT NULL,
    SessionDateKey    INT            NOT NULL,
    SessionHour       INT            NOT NULL,
    SecondsWatched    INT            NOT NULL,
    PercentComplete   DECIMAL(5,2)   NOT NULL,
    VideoQuality      VARCHAR(4)     NOT NULL,
    IsCompleted       BIT            NOT NULL,
    BufferingEvents   SMALLINT       NOT NULL,
    IsBingeSession    TINYINT        NOT NULL,
    CONSTRAINT PK_StgWatchSession PRIMARY KEY (WatchSessionID)
);
GO

CREATE TABLE etl.StgPayment
(
    PaymentID         INT            NOT NULL,
    InvoiceID         INT            NOT NULL,
    InvoiceNumber     VARCHAR(20)    NOT NULL,
    SubscriptionID    INT            NOT NULL,
    SubscriberID      INT            NOT NULL,
    PlanID            INT            NOT NULL,
    PaymentMethodID   INT            NOT NULL,
    BillingCountryID  INT            NOT NULL,
    IssuedDate        DATE           NOT NULL,
    PaidAt            DATETIME2(0)   NOT NULL,
    PaidDate          DATE           NOT NULL,
    PaidHour          INT            NOT NULL,
    InvoiceDateKey    INT            NOT NULL,
    PaymentDateKey    INT            NOT NULL,
    PeriodStart       DATE           NOT NULL,
    PeriodEnd         DATE           NOT NULL,
    InvoiceStatus     VARCHAR(14)    NOT NULL,
    PaymentStatus     VARCHAR(10)    NOT NULL,
    CurrencyCode      CHAR(3)        NOT NULL,
    InvoiceSubtotal   DECIMAL(10,2)  NOT NULL,
    InvoiceDiscount   DECIMAL(10,2)  NOT NULL,
    InvoiceTax        DECIMAL(10,2)  NOT NULL,
    InvoiceTotal      DECIMAL(10,2)  NOT NULL,
    PaymentAmount     DECIMAL(10,2)  NOT NULL,
    AllocationRatio   DECIMAL(9,6)   NOT NULL,
    DaysToPay         INT            NULL,
    CONSTRAINT PK_StgPayment PRIMARY KEY (PaymentID)
);
GO

CREATE TABLE etl.StgReview
(
    ReviewID        INT            NOT NULL,
    ProfileID       INT            NOT NULL,
    SubscriberID    INT            NOT NULL,
    TitleID         INT            NOT NULL,
    PrimaryGenreID  INT            NULL,
    CountryID       INT            NOT NULL,
    RatingValue     TINYINT        NOT NULL,
    HelpfulVotes    INT            NOT NULL,
    HasTextFlag     TINYINT        NOT NULL,
    IsFlaggedFlag   TINYINT        NOT NULL,
    ReviewLength    INT            NOT NULL,
    CreatedAt       DATETIME2(0)   NOT NULL,
    UpdatedAt       DATETIME2(0)   NULL,
    ReviewDate      DATE           NOT NULL,
    ReviewDateKey   INT            NOT NULL,
    ReviewHour      INT            NOT NULL,
    CONSTRAINT PK_StgReview PRIMARY KEY (ReviewID)
);
GO

PRINT 'HBOMaxDW: etl control and staging tables created; watermarks seeded.';
GO
