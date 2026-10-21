/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    02_tables.sql
   Purpose: 27 OLTP tables in 3NF across five business schemas plus audit, matching the
            Crow's Foot logical model in docs/diagrams/02-logical-crowsfoot.drawio.
   Target:  Microsoft SQL Server 2019+
   Depends: 01_create_database.sql must have run first.

   Legend of integrity rules used throughout:
     - Surrogate INT identity PKs with explicit UNIQUE constraints on natural
       keys (email, iso codes, invoice numbers, etc.).
     - FKs declared inline. NO CASCADE on anything that would allow business
       rows to disappear silently; set NULL only where a nullable FK makes
       sense.
     - CHECK constraints enforce enumerations (statuses, roles, device types),
       value ranges (ratings, percentages), and date orderings.
   ============================================================================= */

USE HBOMaxOLTP;
GO

/* =============================================================================
   geo schema - reference data for countries used by every other schema
   ============================================================================= */

CREATE TABLE geo.Country
(
    CountryID       INT             IDENTITY(1,1) NOT NULL,
    IsoAlpha2       CHAR(2)         NOT NULL,
    IsoAlpha3       CHAR(3)         NOT NULL,
    CountryName     NVARCHAR(100)   NOT NULL,
    RegionName      NVARCHAR(30)    NOT NULL,
    CurrencyCode    CHAR(3)         NOT NULL,
    LaunchDate      DATE            NULL,
    IsLaunched      BIT             NOT NULL CONSTRAINT DF_Country_IsLaunched DEFAULT (0),
    CONSTRAINT PK_Country       PRIMARY KEY (CountryID),
    CONSTRAINT UQ_Country_IsoA2 UNIQUE (IsoAlpha2),
    CONSTRAINT UQ_Country_IsoA3 UNIQUE (IsoAlpha3),
    CONSTRAINT CK_Country_Launch
        CHECK (IsLaunched = 0 OR LaunchDate IS NOT NULL)
);
GO

/* =============================================================================
   cat schema - the content catalogue
   ============================================================================= */

CREATE TABLE cat.Genre
(
    GenreID     INT             IDENTITY(1,1) NOT NULL,
    GenreName   NVARCHAR(50)    NOT NULL,
    Description NVARCHAR(200)   NULL,
    CONSTRAINT PK_Genre       PRIMARY KEY (GenreID),
    CONSTRAINT UQ_Genre_Name  UNIQUE (GenreName)
);
GO

CREATE TABLE cat.Language
(
    LanguageID    INT           IDENTITY(1,1) NOT NULL,
    IsoCode       VARCHAR(5)    NOT NULL,
    LanguageName  NVARCHAR(60)  NOT NULL,
    CONSTRAINT PK_Language       PRIMARY KEY (LanguageID),
    CONSTRAINT UQ_Language_Iso   UNIQUE (IsoCode),
    CONSTRAINT UQ_Language_Name  UNIQUE (LanguageName)
);
GO

CREATE TABLE cat.Person
(
    PersonID        INT             IDENTITY(1,1) NOT NULL,
    FullName        NVARCHAR(120)   NOT NULL,
    BirthDate       DATE            NULL,
    DeathDate       DATE            NULL,
    BirthCountryID  INT             NULL,
    Gender          CHAR(1)         NULL,
    Biography       NVARCHAR(1000)  NULL,
    PhotoUrl        NVARCHAR(300)   NULL,
    CONSTRAINT PK_Person           PRIMARY KEY (PersonID),
    CONSTRAINT FK_Person_Country   FOREIGN KEY (BirthCountryID)   REFERENCES geo.Country (CountryID),
    CONSTRAINT CK_Person_Gender    CHECK (Gender IS NULL OR Gender IN ('M','F','X')),
    CONSTRAINT CK_Person_Dates     CHECK (DeathDate IS NULL OR BirthDate IS NULL OR DeathDate >= BirthDate)
);
GO

CREATE TABLE cat.Studio
(
    StudioID                INT             IDENTITY(1,1) NOT NULL,
    StudioName              NVARCHAR(100)   NOT NULL,
    FoundedYear             SMALLINT        NULL,
    HeadquartersCountryID   INT             NULL,
    Website                 NVARCHAR(200)   NULL,
    CONSTRAINT PK_Studio            PRIMARY KEY (StudioID),
    CONSTRAINT UQ_Studio_Name       UNIQUE (StudioName),
    CONSTRAINT FK_Studio_Country    FOREIGN KEY (HeadquartersCountryID) REFERENCES geo.Country (CountryID),
    CONSTRAINT CK_Studio_Founded    CHECK (FoundedYear IS NULL OR FoundedYear BETWEEN 1800 AND 2100)
);
GO

CREATE TABLE cat.Title
(
    TitleID              INT             IDENTITY(1,1) NOT NULL,
    PrimaryTitle         NVARCHAR(200)   NOT NULL,
    OriginalTitle        NVARCHAR(200)   NULL,
    TitleType            VARCHAR(12)     NOT NULL,
    ReleaseYear          SMALLINT        NOT NULL,
    MaturityRating       VARCHAR(5)      NOT NULL,
    RuntimeMinutes       SMALLINT        NULL,
    Synopsis             NVARCHAR(1000)  NULL,
    PosterUrl            NVARCHAR(300)   NULL,
    TrailerUrl           NVARCHAR(300)   NULL,
    OriginalLanguageID   INT             NOT NULL,
    StudioID             INT             NULL,
    IsHboOriginal        BIT             NOT NULL CONSTRAINT DF_Title_IsHbo DEFAULT (0),
    ProductionBudgetUsd  DECIMAL(14,2)   NULL,
    ImdbRating           DECIMAL(3,1)    NULL,
    AverageUserRating    DECIMAL(4,2)    NULL,
    UserRatingCount      INT             NOT NULL CONSTRAINT DF_Title_RatingCount DEFAULT (0),
    AddedToCatalogAt     DATETIME2(0)    NOT NULL CONSTRAINT DF_Title_AddedAt DEFAULT (SYSUTCDATETIME()),
    RemovedFromCatalogAt DATETIME2(0)    NULL,
    CONSTRAINT PK_Title              PRIMARY KEY (TitleID),
    CONSTRAINT FK_Title_Language     FOREIGN KEY (OriginalLanguageID) REFERENCES cat.Language (LanguageID),
    CONSTRAINT FK_Title_Studio       FOREIGN KEY (StudioID)           REFERENCES cat.Studio (StudioID),
    CONSTRAINT CK_Title_Type         CHECK (TitleType IN ('Movie','Series','Documentary','StandUp','Short')),
    CONSTRAINT CK_Title_Year         CHECK (ReleaseYear BETWEEN 1900 AND 2100),
    CONSTRAINT CK_Title_Rating       CHECK (MaturityRating IN ('G','PG','PG-13','R','NC-17','TV-Y','TV-Y7','TV-G','TV-PG','TV-14','TV-MA')),
    CONSTRAINT CK_Title_Runtime      CHECK (RuntimeMinutes IS NULL OR RuntimeMinutes BETWEEN 1 AND 1200),
    CONSTRAINT CK_Title_ImdbRange    CHECK (ImdbRating IS NULL OR ImdbRating BETWEEN 0 AND 10),
    CONSTRAINT CK_Title_AvgRange     CHECK (AverageUserRating IS NULL OR AverageUserRating BETWEEN 0 AND 10),
    CONSTRAINT CK_Title_Removed      CHECK (RemovedFromCatalogAt IS NULL OR RemovedFromCatalogAt >= AddedToCatalogAt)
);
GO

CREATE TABLE cat.Season
(
    SeasonID       INT             IDENTITY(1,1) NOT NULL,
    TitleID        INT             NOT NULL,
    SeasonNumber   TINYINT         NOT NULL,
    SeasonTitle    NVARCHAR(120)   NULL,
    ReleaseYear    SMALLINT        NULL,
    EpisodeCount   SMALLINT        NOT NULL CONSTRAINT DF_Season_EpisodeCount DEFAULT (0),
    Synopsis       NVARCHAR(600)   NULL,
    CONSTRAINT PK_Season           PRIMARY KEY (SeasonID),
    CONSTRAINT FK_Season_Title     FOREIGN KEY (TitleID) REFERENCES cat.Title (TitleID) ON DELETE CASCADE,
    CONSTRAINT UQ_Season_PerTitle  UNIQUE (TitleID, SeasonNumber),
    CONSTRAINT CK_Season_Episodes  CHECK (EpisodeCount >= 0)
);
GO

CREATE TABLE cat.Episode
(
    EpisodeID       INT             IDENTITY(1,1) NOT NULL,
    SeasonID        INT             NOT NULL,
    EpisodeNumber   SMALLINT        NOT NULL,
    EpisodeTitle    NVARCHAR(200)   NOT NULL,
    RuntimeMinutes  SMALLINT        NOT NULL,
    AirDate         DATE            NULL,
    Synopsis        NVARCHAR(600)   NULL,
    StillUrl        NVARCHAR(300)   NULL,
    CONSTRAINT PK_Episode            PRIMARY KEY (EpisodeID),
    CONSTRAINT FK_Episode_Season     FOREIGN KEY (SeasonID) REFERENCES cat.Season (SeasonID) ON DELETE CASCADE,
    CONSTRAINT UQ_Episode_PerSeason  UNIQUE (SeasonID, EpisodeNumber),
    CONSTRAINT CK_Episode_Runtime    CHECK (RuntimeMinutes BETWEEN 1 AND 600)
);
GO

CREATE TABLE cat.TitleGenre
(
    TitleID         INT     NOT NULL,
    GenreID         INT     NOT NULL,
    IsPrimaryGenre  BIT     NOT NULL CONSTRAINT DF_TitleGenre_Primary DEFAULT (0),
    CONSTRAINT PK_TitleGenre         PRIMARY KEY (TitleID, GenreID),
    CONSTRAINT FK_TitleGenre_Title   FOREIGN KEY (TitleID) REFERENCES cat.Title (TitleID) ON DELETE CASCADE,
    CONSTRAINT FK_TitleGenre_Genre   FOREIGN KEY (GenreID) REFERENCES cat.Genre (GenreID)
);
GO

CREATE TABLE cat.Credit
(
    CreditID       INT             IDENTITY(1,1) NOT NULL,
    TitleID        INT             NOT NULL,
    PersonID       INT             NOT NULL,
    CreditRole     VARCHAR(16)     NOT NULL,
    CharacterName  NVARCHAR(120)   NULL,
    BillingOrder   TINYINT         NULL,
    CONSTRAINT PK_Credit             PRIMARY KEY (CreditID),
    CONSTRAINT FK_Credit_Title       FOREIGN KEY (TitleID)  REFERENCES cat.Title  (TitleID) ON DELETE CASCADE,
    CONSTRAINT FK_Credit_Person      FOREIGN KEY (PersonID) REFERENCES cat.Person (PersonID),
    CONSTRAINT CK_Credit_Role        CHECK (CreditRole IN ('Director','Writer','Actor','Producer','Composer','Cinematographer','Editor')),
    CONSTRAINT UQ_Credit_PerRole     UNIQUE (TitleID, PersonID, CreditRole)
);
GO

CREATE TABLE cat.TitleLanguageTrack
(
    TitleID          INT         NOT NULL,
    LanguageID       INT         NOT NULL,
    TrackType        VARCHAR(8)  NOT NULL,
    IsClosedCaption  BIT         NOT NULL CONSTRAINT DF_TLT_ClosedCaption DEFAULT (0),
    CONSTRAINT PK_TitleLangTrack       PRIMARY KEY (TitleID, LanguageID, TrackType),
    CONSTRAINT FK_TLT_Title            FOREIGN KEY (TitleID)    REFERENCES cat.Title    (TitleID) ON DELETE CASCADE,
    CONSTRAINT FK_TLT_Language         FOREIGN KEY (LanguageID) REFERENCES cat.Language (LanguageID),
    CONSTRAINT CK_TLT_Type             CHECK (TrackType IN ('Audio','Subtitle','Dubbed'))
);
GO

CREATE TABLE cat.TitleAvailability
(
    TitleID        INT          NOT NULL,
    CountryID      INT          NOT NULL,
    AvailableFrom  DATE         NOT NULL,
    AvailableUntil DATE         NULL,
    LicenseType    VARCHAR(14)  NOT NULL,
    CONSTRAINT PK_TitleAvail           PRIMARY KEY (TitleID, CountryID),
    CONSTRAINT FK_TitleAvail_Title     FOREIGN KEY (TitleID)   REFERENCES cat.Title   (TitleID) ON DELETE CASCADE,
    CONSTRAINT FK_TitleAvail_Country   FOREIGN KEY (CountryID) REFERENCES geo.Country (CountryID),
    CONSTRAINT CK_TitleAvail_License   CHECK (LicenseType IN ('Owned','Licensed','Exclusive','Expired')),
    CONSTRAINT CK_TitleAvail_Dates     CHECK (AvailableUntil IS NULL OR AvailableUntil >= AvailableFrom)
);
GO

/* =============================================================================
   acct schema - subscribers, plans, subscriptions, profiles, devices
   ============================================================================= */

CREATE TABLE acct.Subscriber
(
    SubscriberID         INT             IDENTITY(1,1) NOT NULL,
    Email                NVARCHAR(256)   NOT NULL,
    PasswordHash         VARBINARY(64)   NOT NULL,
    FirstName            NVARCHAR(60)    NOT NULL,
    LastName             NVARCHAR(60)    NOT NULL,
    DateOfBirth          DATE            NOT NULL,
    Gender               CHAR(1)         NULL,
    PhoneNumber          VARCHAR(25)     NULL,
    CountryID            INT             NOT NULL,
    PreferredLanguageID  INT             NOT NULL,
    RegisteredAt         DATETIME2(0)    NOT NULL CONSTRAINT DF_Subscriber_Registered DEFAULT (SYSUTCDATETIME()),
    LastLoginAt          DATETIME2(0)    NULL,
    MarketingOptIn       BIT             NOT NULL CONSTRAINT DF_Subscriber_Marketing DEFAULT (0),
    AccountStatus        VARCHAR(12)     NOT NULL CONSTRAINT DF_Subscriber_Status DEFAULT ('Active'),
    CONSTRAINT PK_Subscriber             PRIMARY KEY (SubscriberID),
    CONSTRAINT UQ_Subscriber_Email       UNIQUE (Email),
    CONSTRAINT FK_Subscriber_Country     FOREIGN KEY (CountryID)           REFERENCES geo.Country  (CountryID),
    CONSTRAINT FK_Subscriber_Language    FOREIGN KEY (PreferredLanguageID) REFERENCES cat.Language (LanguageID),
    CONSTRAINT CK_Subscriber_Gender      CHECK (Gender IS NULL OR Gender IN ('M','F','X')),
    CONSTRAINT CK_Subscriber_Status      CHECK (AccountStatus IN ('Active','Suspended','Closed','PendingVerify')),
    CONSTRAINT CK_Subscriber_Email       CHECK (Email LIKE '%_@_%._%')
);
GO

CREATE TABLE acct.[Plan]
(
    PlanID                INT             IDENTITY(1,1) NOT NULL,
    PlanCode              VARCHAR(20)     NOT NULL,
    PlanName              NVARCHAR(60)    NOT NULL,
    MonthlyPrice          DECIMAL(8,2)    NOT NULL,
    AnnualPrice           DECIMAL(8,2)    NULL,
    CurrencyCode          CHAR(3)         NOT NULL,
    MaxConcurrentStreams  TINYINT         NOT NULL,
    MaxVideoQuality       VARCHAR(4)      NOT NULL,
    MaxProfiles           TINYINT         NOT NULL,
    AllowsDownloads       BIT             NOT NULL CONSTRAINT DF_Plan_Downloads DEFAULT (0),
    HasAdvertising        BIT             NOT NULL CONSTRAINT DF_Plan_Ads       DEFAULT (0),
    EffectiveFrom         DATE            NOT NULL,
    IsActive              BIT             NOT NULL CONSTRAINT DF_Plan_IsActive  DEFAULT (1),
    CONSTRAINT PK_Plan            PRIMARY KEY (PlanID),
    CONSTRAINT UQ_Plan_Code       UNIQUE (PlanCode),
    CONSTRAINT CK_Plan_Price      CHECK (MonthlyPrice >= 0 AND (AnnualPrice IS NULL OR AnnualPrice >= 0)),
    CONSTRAINT CK_Plan_Quality    CHECK (MaxVideoQuality IN ('SD','HD','FHD','4K')),
    CONSTRAINT CK_Plan_Streams    CHECK (MaxConcurrentStreams BETWEEN 1 AND 10),
    CONSTRAINT CK_Plan_Profiles   CHECK (MaxProfiles BETWEEN 1 AND 10)
);
GO

CREATE TABLE acct.Subscription
(
    SubscriptionID       INT             IDENTITY(1,1) NOT NULL,
    SubscriberID         INT             NOT NULL,
    PlanID               INT             NOT NULL,
    StartDate            DATE            NOT NULL,
    EndDate              DATE            NULL,
    SubscriptionStatus   VARCHAR(12)     NOT NULL CONSTRAINT DF_Sub_Status DEFAULT ('Active'),
    BillingCycle         VARCHAR(8)      NOT NULL CONSTRAINT DF_Sub_Cycle  DEFAULT ('Monthly'),
    AutoRenew            BIT             NOT NULL CONSTRAINT DF_Sub_AutoRenew DEFAULT (1),
    TrialEndsOn          DATE            NULL,
    NextBillingDate      DATE            NULL,
    CancelledAt          DATETIME2(0)    NULL,
    CancellationReason   NVARCHAR(200)   NULL,
    CONSTRAINT PK_Subscription            PRIMARY KEY (SubscriptionID),
    CONSTRAINT FK_Sub_Subscriber          FOREIGN KEY (SubscriberID) REFERENCES acct.Subscriber (SubscriberID),
    CONSTRAINT FK_Sub_Plan                FOREIGN KEY (PlanID)       REFERENCES acct.[Plan]       (PlanID),
    CONSTRAINT CK_Sub_Status              CHECK (SubscriptionStatus IN ('Active','Trialing','Paused','Cancelled','Expired','PastDue')),
    CONSTRAINT CK_Sub_Cycle               CHECK (BillingCycle IN ('Monthly','Annual')),
    CONSTRAINT CK_Sub_Dates               CHECK (EndDate IS NULL OR EndDate >= StartDate)
);
GO

CREATE TABLE acct.Profile
(
    ProfileID             INT             IDENTITY(1,1) NOT NULL,
    SubscriberID          INT             NOT NULL,
    ProfileName           NVARCHAR(50)    NOT NULL,
    AvatarUrl             NVARCHAR(300)   NULL,
    IsKidsProfile         BIT             NOT NULL CONSTRAINT DF_Profile_Kids DEFAULT (0),
    MaturityCeiling       VARCHAR(5)      NOT NULL CONSTRAINT DF_Profile_Mat  DEFAULT ('TV-MA'),
    PreferredLanguageID   INT             NOT NULL,
    AutoplayNextEpisode   BIT             NOT NULL CONSTRAINT DF_Profile_Autoplay DEFAULT (1),
    CreatedAt             DATETIME2(0)    NOT NULL CONSTRAINT DF_Profile_Created  DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_Profile              PRIMARY KEY (ProfileID),
    CONSTRAINT FK_Profile_Subscriber   FOREIGN KEY (SubscriberID)        REFERENCES acct.Subscriber (SubscriberID) ON DELETE CASCADE,
    CONSTRAINT FK_Profile_Language     FOREIGN KEY (PreferredLanguageID) REFERENCES cat.Language    (LanguageID),
    CONSTRAINT UQ_Profile_PerName      UNIQUE (SubscriberID, ProfileName),
    CONSTRAINT CK_Profile_Maturity     CHECK (MaturityCeiling IN ('G','PG','PG-13','R','NC-17','TV-Y','TV-Y7','TV-G','TV-PG','TV-14','TV-MA'))
);
GO

CREATE TABLE acct.Device
(
    DeviceID            INT             IDENTITY(1,1) NOT NULL,
    SubscriberID        INT             NOT NULL,
    DeviceType          VARCHAR(16)     NOT NULL,
    Manufacturer        NVARCHAR(50)    NOT NULL,
    ModelName           NVARCHAR(60)    NULL,
    OperatingSystem     NVARCHAR(40)    NULL,
    AppVersion          VARCHAR(20)     NULL,
    DeviceFingerprint   VARCHAR(64)     NOT NULL,
    RegisteredAt        DATETIME2(0)    NOT NULL CONSTRAINT DF_Device_Registered DEFAULT (SYSUTCDATETIME()),
    LastSeenAt          DATETIME2(0)    NULL,
    IsTrusted           BIT             NOT NULL CONSTRAINT DF_Device_Trusted DEFAULT (0),
    CONSTRAINT PK_Device              PRIMARY KEY (DeviceID),
    CONSTRAINT FK_Device_Subscriber   FOREIGN KEY (SubscriberID) REFERENCES acct.Subscriber (SubscriberID) ON DELETE CASCADE,
    CONSTRAINT UQ_Device_Fingerprint  UNIQUE (SubscriberID, DeviceFingerprint),
    CONSTRAINT CK_Device_Type         CHECK (DeviceType IN ('SmartTV','Mobile','Tablet','Laptop','Desktop','Console','StreamingBox','Browser'))
);
GO

/* =============================================================================
   play schema - viewing, engagement
   ============================================================================= */

CREATE TABLE play.WatchSession
(
    WatchSessionID    BIGINT          IDENTITY(1,1) NOT NULL,
    ProfileID         INT             NOT NULL,
    TitleID           INT             NOT NULL,
    EpisodeID         INT             NULL,
    DeviceID          INT             NOT NULL,
    CountryID         INT             NOT NULL,
    StartedAt         DATETIME2(0)    NOT NULL,
    EndedAt           DATETIME2(0)    NULL,
    SecondsWatched    INT             NOT NULL CONSTRAINT DF_WS_Seconds DEFAULT (0),
    PercentComplete   DECIMAL(5,2)    NOT NULL CONSTRAINT DF_WS_Pct     DEFAULT (0),
    VideoQuality      VARCHAR(4)      NOT NULL,
    IsCompleted       BIT             NOT NULL CONSTRAINT DF_WS_Complete DEFAULT (0),
    BufferingEvents   SMALLINT        NOT NULL CONSTRAINT DF_WS_Buffer   DEFAULT (0),
    CONSTRAINT PK_WatchSession         PRIMARY KEY (WatchSessionID),
    CONSTRAINT FK_WS_Profile           FOREIGN KEY (ProfileID) REFERENCES acct.Profile (ProfileID),
    CONSTRAINT FK_WS_Title             FOREIGN KEY (TitleID)   REFERENCES cat.Title    (TitleID),
    CONSTRAINT FK_WS_Episode           FOREIGN KEY (EpisodeID) REFERENCES cat.Episode  (EpisodeID),
    CONSTRAINT FK_WS_Device            FOREIGN KEY (DeviceID)  REFERENCES acct.Device  (DeviceID),
    CONSTRAINT FK_WS_Country           FOREIGN KEY (CountryID) REFERENCES geo.Country  (CountryID),
    CONSTRAINT CK_WS_Quality           CHECK (VideoQuality IN ('SD','HD','FHD','4K')),
    CONSTRAINT CK_WS_Seconds           CHECK (SecondsWatched >= 0),
    CONSTRAINT CK_WS_Pct               CHECK (PercentComplete BETWEEN 0 AND 100),
    CONSTRAINT CK_WS_Buffer            CHECK (BufferingEvents >= 0),
    CONSTRAINT CK_WS_Ended             CHECK (EndedAt IS NULL OR EndedAt >= StartedAt)
);
GO

CREATE TABLE play.Watchlist
(
    ProfileID     INT          NOT NULL,
    TitleID       INT          NOT NULL,
    AddedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_Watchlist_Added DEFAULT (SYSUTCDATETIME()),
    SortPriority  SMALLINT     NOT NULL CONSTRAINT DF_Watchlist_Sort  DEFAULT (0),
    CONSTRAINT PK_Watchlist           PRIMARY KEY (ProfileID, TitleID),
    CONSTRAINT FK_Watchlist_Profile   FOREIGN KEY (ProfileID) REFERENCES acct.Profile (ProfileID) ON DELETE CASCADE,
    CONSTRAINT FK_Watchlist_Title     FOREIGN KEY (TitleID)   REFERENCES cat.Title    (TitleID)
);
GO

CREATE TABLE play.Review
(
    ReviewID      INT             IDENTITY(1,1) NOT NULL,
    ProfileID     INT             NOT NULL,
    TitleID       INT             NOT NULL,
    RatingValue   TINYINT         NOT NULL,
    ReviewTitle   NVARCHAR(150)   NULL,
    ReviewText    NVARCHAR(2000)  NULL,
    CreatedAt     DATETIME2(0)    NOT NULL CONSTRAINT DF_Review_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAt     DATETIME2(0)    NULL,
    HelpfulVotes  INT             NOT NULL CONSTRAINT DF_Review_Helpful DEFAULT (0),
    IsFlagged     BIT             NOT NULL CONSTRAINT DF_Review_Flagged DEFAULT (0),
    CONSTRAINT PK_Review          PRIMARY KEY (ReviewID),
    CONSTRAINT FK_Review_Profile  FOREIGN KEY (ProfileID) REFERENCES acct.Profile (ProfileID) ON DELETE CASCADE,
    CONSTRAINT FK_Review_Title    FOREIGN KEY (TitleID)   REFERENCES cat.Title    (TitleID),
    CONSTRAINT UQ_Review_PerUser  UNIQUE (ProfileID, TitleID),
    CONSTRAINT CK_Review_Rating   CHECK (RatingValue BETWEEN 1 AND 10),
    CONSTRAINT CK_Review_Helpful  CHECK (HelpfulVotes >= 0),
    CONSTRAINT CK_Review_Updated  CHECK (UpdatedAt IS NULL OR UpdatedAt >= CreatedAt)
);
GO

CREATE TABLE play.Download
(
    DownloadID       INT             IDENTITY(1,1) NOT NULL,
    ProfileID        INT             NOT NULL,
    DeviceID         INT             NOT NULL,
    TitleID          INT             NOT NULL,
    EpisodeID        INT             NULL,
    DownloadedAt     DATETIME2(0)    NOT NULL CONSTRAINT DF_Download_At DEFAULT (SYSUTCDATETIME()),
    ExpiresAt        DATETIME2(0)    NULL,
    FileSizeMb       DECIMAL(10,2)   NULL,
    DownloadStatus   VARCHAR(12)     NOT NULL CONSTRAINT DF_Download_Status DEFAULT ('Completed'),
    CONSTRAINT PK_Download           PRIMARY KEY (DownloadID),
    CONSTRAINT FK_Download_Profile   FOREIGN KEY (ProfileID) REFERENCES acct.Profile (ProfileID) ON DELETE CASCADE,
    CONSTRAINT FK_Download_Device    FOREIGN KEY (DeviceID)  REFERENCES acct.Device  (DeviceID),
    CONSTRAINT FK_Download_Title     FOREIGN KEY (TitleID)   REFERENCES cat.Title    (TitleID),
    CONSTRAINT FK_Download_Episode   FOREIGN KEY (EpisodeID) REFERENCES cat.Episode  (EpisodeID),
    CONSTRAINT CK_Download_Status    CHECK (DownloadStatus IN ('Queued','Downloading','Completed','Failed','Expired','Deleted')),
    CONSTRAINT CK_Download_Size      CHECK (FileSizeMb IS NULL OR FileSizeMb >= 0)
);
GO

/* =============================================================================
   bill schema - payment methods, invoices, payments, coupons
   ============================================================================= */

CREATE TABLE bill.PaymentMethod
(
    PaymentMethodID    INT             IDENTITY(1,1) NOT NULL,
    SubscriberID       INT             NOT NULL,
    MethodType         VARCHAR(12)     NOT NULL,
    CardBrand          VARCHAR(20)     NULL,
    Last4Digits        CHAR(4)         NULL,
    ExpiryMonth        TINYINT         NULL,
    ExpiryYear         SMALLINT        NULL,
    BillingCountryID   INT             NOT NULL,
    BillingPostalCode  VARCHAR(20)     NULL,
    IsDefault          BIT             NOT NULL CONSTRAINT DF_PM_Default DEFAULT (0),
    IsActive           BIT             NOT NULL CONSTRAINT DF_PM_Active  DEFAULT (1),
    AddedAt            DATETIME2(0)    NOT NULL CONSTRAINT DF_PM_Added   DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_PaymentMethod       PRIMARY KEY (PaymentMethodID),
    CONSTRAINT FK_PM_Subscriber       FOREIGN KEY (SubscriberID)     REFERENCES acct.Subscriber (SubscriberID) ON DELETE CASCADE,
    CONSTRAINT FK_PM_Country          FOREIGN KEY (BillingCountryID) REFERENCES geo.Country     (CountryID),
    CONSTRAINT CK_PM_Type             CHECK (MethodType IN ('CreditCard','DebitCard','PayPal','AppleIAP','GoogleIAP','GiftCard','BankTransfer')),
    CONSTRAINT CK_PM_ExpiryMonth      CHECK (ExpiryMonth IS NULL OR ExpiryMonth BETWEEN 1 AND 12),
    CONSTRAINT CK_PM_ExpiryYear       CHECK (ExpiryYear  IS NULL OR ExpiryYear  BETWEEN 2000 AND 2100)
);
GO

CREATE TABLE bill.Invoice
(
    InvoiceID        INT             IDENTITY(1,1) NOT NULL,
    SubscriptionID   INT             NOT NULL,
    InvoiceNumber    VARCHAR(20)     NOT NULL,
    IssuedDate       DATE            NOT NULL,
    DueDate          DATE            NOT NULL,
    PeriodStart      DATE            NOT NULL,
    PeriodEnd        DATE            NOT NULL,
    SubtotalAmount   DECIMAL(10,2)   NOT NULL,
    DiscountAmount   DECIMAL(10,2)   NOT NULL CONSTRAINT DF_Inv_Discount DEFAULT (0),
    TaxAmount        DECIMAL(10,2)   NOT NULL CONSTRAINT DF_Inv_Tax      DEFAULT (0),
    TotalAmount      DECIMAL(10,2)   NOT NULL,
    CurrencyCode     CHAR(3)         NOT NULL,
    InvoiceStatus    VARCHAR(14)     NOT NULL CONSTRAINT DF_Inv_Status   DEFAULT ('Open'),
    CONSTRAINT PK_Invoice           PRIMARY KEY (InvoiceID),
    CONSTRAINT UQ_Invoice_Number    UNIQUE (InvoiceNumber),
    CONSTRAINT FK_Invoice_Sub       FOREIGN KEY (SubscriptionID) REFERENCES acct.Subscription (SubscriptionID),
    CONSTRAINT CK_Invoice_Status    CHECK (InvoiceStatus IN ('Open','Paid','PartiallyPaid','Overdue','Void','Refunded')),
    CONSTRAINT CK_Invoice_Period    CHECK (PeriodEnd >= PeriodStart),
    CONSTRAINT CK_Invoice_Amounts   CHECK (SubtotalAmount >= 0 AND DiscountAmount >= 0 AND TaxAmount >= 0 AND TotalAmount >= 0)
);
GO

CREATE TABLE bill.Payment
(
    PaymentID          INT             IDENTITY(1,1) NOT NULL,
    InvoiceID          INT             NOT NULL,
    PaymentMethodID    INT             NOT NULL,
    PaidAt             DATETIME2(0)    NOT NULL CONSTRAINT DF_Pay_PaidAt DEFAULT (SYSUTCDATETIME()),
    Amount             DECIMAL(10,2)   NOT NULL,
    CurrencyCode       CHAR(3)         NOT NULL,
    PaymentStatus      VARCHAR(10)     NOT NULL CONSTRAINT DF_Pay_Status DEFAULT ('Succeeded'),
    GatewayReference   VARCHAR(50)     NULL,
    FailureReason      NVARCHAR(200)   NULL,
    CONSTRAINT PK_Payment            PRIMARY KEY (PaymentID),
    CONSTRAINT FK_Payment_Invoice    FOREIGN KEY (InvoiceID)       REFERENCES bill.Invoice       (InvoiceID),
    CONSTRAINT FK_Payment_Method     FOREIGN KEY (PaymentMethodID) REFERENCES bill.PaymentMethod (PaymentMethodID),
    CONSTRAINT CK_Payment_Status     CHECK (PaymentStatus IN ('Pending','Succeeded','Failed','Refunded','Chargeback')),
    CONSTRAINT CK_Payment_Amount     CHECK (Amount >= 0)
);
GO

CREATE TABLE bill.Coupon
(
    CouponID         INT             IDENTITY(1,1) NOT NULL,
    CouponCode       VARCHAR(30)     NOT NULL,
    Description      NVARCHAR(200)   NULL,
    DiscountPercent  DECIMAL(5,2)    NULL,
    DiscountAmount   DECIMAL(8,2)    NULL,
    ValidFrom        DATE            NOT NULL,
    ValidTo          DATE            NOT NULL,
    MaxRedemptions   INT             NULL,
    TimesRedeemed    INT             NOT NULL CONSTRAINT DF_Coupon_Redeemed DEFAULT (0),
    CONSTRAINT PK_Coupon          PRIMARY KEY (CouponID),
    CONSTRAINT UQ_Coupon_Code     UNIQUE (CouponCode),
    CONSTRAINT CK_Coupon_Dates    CHECK (ValidTo >= ValidFrom),
    CONSTRAINT CK_Coupon_Pct      CHECK (DiscountPercent IS NULL OR DiscountPercent BETWEEN 0 AND 100),
    CONSTRAINT CK_Coupon_Amount   CHECK (DiscountAmount  IS NULL OR DiscountAmount >= 0),
    CONSTRAINT CK_Coupon_HasOne   CHECK (DiscountPercent IS NOT NULL OR DiscountAmount IS NOT NULL),
    CONSTRAINT CK_Coupon_Max      CHECK (MaxRedemptions IS NULL OR MaxRedemptions > 0),
    CONSTRAINT CK_Coupon_Used     CHECK (TimesRedeemed >= 0)
);
GO

CREATE TABLE bill.SubscriptionCoupon
(
    SubscriptionID  INT             NOT NULL,
    CouponID        INT             NOT NULL,
    AppliedAt       DATETIME2(0)    NOT NULL CONSTRAINT DF_SC_Applied DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_SubscriptionCoupon       PRIMARY KEY (SubscriptionID, CouponID),
    CONSTRAINT FK_SC_Subscription          FOREIGN KEY (SubscriptionID) REFERENCES acct.Subscription (SubscriptionID),
    CONSTRAINT FK_SC_Coupon                FOREIGN KEY (CouponID)       REFERENCES bill.Coupon       (CouponID)
);
GO

/* =============================================================================
   audit schema - append-only history written by triggers
   ============================================================================= */

CREATE TABLE audit.SubscriptionChangeLog
(
    ChangeLogID       BIGINT          IDENTITY(1,1) NOT NULL,
    SubscriptionID    INT             NOT NULL,
    ChangeType        VARCHAR(20)     NOT NULL,
    OldPlanID         INT             NULL,
    NewPlanID         INT             NULL,
    OldStatus         VARCHAR(12)     NULL,
    NewStatus         VARCHAR(12)     NULL,
    ChangedAt         DATETIME2(0)    NOT NULL CONSTRAINT DF_SubChg_At DEFAULT (SYSUTCDATETIME()),
    ChangedBy         NVARCHAR(128)   NOT NULL CONSTRAINT DF_SubChg_By DEFAULT (SUSER_SNAME()),
    CONSTRAINT PK_SubChangeLog        PRIMARY KEY (ChangeLogID),
    CONSTRAINT FK_SubChg_Sub          FOREIGN KEY (SubscriptionID) REFERENCES acct.Subscription (SubscriptionID),
    CONSTRAINT FK_SubChg_OldPlan      FOREIGN KEY (OldPlanID)      REFERENCES acct.[Plan] (PlanID),
    CONSTRAINT FK_SubChg_NewPlan      FOREIGN KEY (NewPlanID)      REFERENCES acct.[Plan] (PlanID),
    CONSTRAINT CK_SubChg_Type         CHECK (ChangeType IN ('Created','PlanChange','StatusChange','PlanAndStatusChange','AutoRenewToggle'))
);
GO

PRINT 'HBOMaxOLTP: 27 tables created (geo.1, acct.5, cat.11, play.4, bill.5, audit.1).';
GO
