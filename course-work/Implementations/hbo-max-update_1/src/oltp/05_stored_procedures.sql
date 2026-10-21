/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    05_stored_procedures.sql
   Purpose: 7 stored procedures that wrap multi-table business operations.
   Target:  Microsoft SQL Server 2019+
   Depends: 02_tables.sql and 04_functions.sql must have run first.

   Procedure                         Business operation
   --------------------------------  -----------------------------------------
   acct.usp_RegisterSubscriber       sign-up: subscriber + subscription (trial)
                                     + first profile, in one transaction
   acct.usp_ChangeSubscriptionPlan   upgrade / downgrade with profile-limit check
   acct.usp_CancelSubscription       cancel now or at the end of the paid period
   play.usp_RecordWatchSession       playback event with entitlement, licence
                                     and video-quality checks
   play.usp_AddOrUpdateReview        one review per profile and title (upsert)
   bill.usp_GenerateInvoice          next invoice of a subscription, with
                                     coupon discount and tax
   bill.usp_RecordPayment            payment attempt; keeps the subscription
                                     status in step (PastDue <-> Active)

   Conventions (the same as the ETL in 14_etl_procedures.sql)
     - SET NOCOUNT ON; SET XACT_ABORT ON.
     - BEGIN TRY / BEGIN TRANSACTION / COMMIT, CATCH -> ROLLBACK -> THROW.
     - Business-rule violations raise THROW 5xxxx with a readable message.
     - New surrogate keys are returned through OUTPUT parameters.
   ============================================================================= */

USE HBOMaxOLTP;
GO

/* =============================================================================
   acct.usp_RegisterSubscriber
   Creates the subscriber, the first subscription (with an optional free trial)
   and a first profile named after the subscriber. The subscription is created
   BEFORE the profile, because acct.trg_Profile_EnforcePlanLimit checks the
   profile count against the plan.
   ============================================================================= */
CREATE OR ALTER PROCEDURE acct.usp_RegisterSubscriber
    @Email                NVARCHAR(256),
    @PasswordHash         VARBINARY(64),
    @FirstName            NVARCHAR(60),
    @LastName             NVARCHAR(60),
    @DateOfBirth          DATE,
    @Gender               CHAR(1)      = NULL,
    @CountryID            INT,
    @PreferredLanguageID  INT,
    @PlanID               INT,
    @BillingCycle         VARCHAR(8)   = 'Monthly',
    @TrialDays            INT          = 7,
    @SubscriberID         INT          = NULL OUTPUT,
    @SubscriptionID       INT          = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF acct.ufn_GetAge(@DateOfBirth, @Today) < 18
        THROW 50001, 'A subscriber must be at least 18 years old.', 1;

    IF NOT EXISTS (SELECT 1 FROM geo.Country WHERE CountryID = @CountryID AND IsLaunched = 1)
        THROW 50002, 'The service is not available in this country.', 1;

    IF NOT EXISTS (SELECT 1 FROM acct.[Plan] WHERE PlanID = @PlanID AND IsActive = 1)
        THROW 50003, 'The selected plan does not exist or is no longer sold.', 1;

    IF EXISTS (SELECT 1 FROM acct.Subscriber WHERE Email = @Email)
        THROW 50004, 'An account with this e-mail address already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO acct.Subscriber
            (Email, PasswordHash, FirstName, LastName, DateOfBirth, Gender,
             CountryID, PreferredLanguageID, AccountStatus)
        VALUES
            (@Email, @PasswordHash, @FirstName, @LastName, @DateOfBirth, @Gender,
             @CountryID, @PreferredLanguageID, 'Active');

        SET @SubscriberID = SCOPE_IDENTITY();

        INSERT INTO acct.Subscription
            (SubscriberID, PlanID, StartDate, SubscriptionStatus, BillingCycle,
             AutoRenew, TrialEndsOn, NextBillingDate)
        VALUES
            (@SubscriberID, @PlanID, @Today,
             CASE WHEN @TrialDays > 0 THEN 'Trialing' ELSE 'Active' END,
             @BillingCycle, 1,
             CASE WHEN @TrialDays > 0 THEN DATEADD(DAY, @TrialDays, @Today) END,
             DATEADD(DAY, CASE WHEN @TrialDays > 0 THEN @TrialDays ELSE 0 END, @Today));

        SET @SubscriptionID = SCOPE_IDENTITY();

        INSERT INTO acct.Profile (SubscriberID, ProfileName, PreferredLanguageID)
        VALUES (@SubscriberID, @FirstName, @PreferredLanguageID);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   acct.usp_ChangeSubscriptionPlan
   Moves a live subscription to another plan. A downgrade is refused while the
   subscriber has more profiles than the new plan allows. The plan history is
   written by acct.trg_Subscription_Audit, not here.
   ============================================================================= */
CREATE OR ALTER PROCEDURE acct.usp_ChangeSubscriptionPlan
    @SubscriptionID INT,
    @NewPlanID      INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SubscriberID INT, @OldPlanID INT, @Status VARCHAR(12),
            @NewMaxProfiles TINYINT, @ProfileCount INT;

    SELECT @SubscriberID = s.SubscriberID, @OldPlanID = s.PlanID, @Status = s.SubscriptionStatus
    FROM acct.Subscription AS s
    WHERE s.SubscriptionID = @SubscriptionID;

    IF @SubscriberID IS NULL
        THROW 50010, 'Subscription not found.', 1;

    IF @Status IN ('Cancelled', 'Expired')
        THROW 50011, 'A cancelled or expired subscription cannot change plan.', 1;

    IF @OldPlanID = @NewPlanID
        THROW 50012, 'The subscription is already on this plan.', 1;

    SELECT @NewMaxProfiles = p.MaxProfiles
    FROM acct.[Plan] AS p
    WHERE p.PlanID = @NewPlanID AND p.IsActive = 1;

    IF @NewMaxProfiles IS NULL
        THROW 50013, 'The target plan does not exist or is no longer sold.', 1;

    SELECT @ProfileCount = COUNT(*) FROM acct.Profile WHERE SubscriberID = @SubscriberID;

    IF @ProfileCount > @NewMaxProfiles
        THROW 50014, 'The subscriber has more profiles than the new plan allows. Remove profiles first.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE acct.Subscription
           SET PlanID = @NewPlanID
         WHERE SubscriptionID = @SubscriptionID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   acct.usp_CancelSubscription
   @Immediate = 0 (default): access continues until the end of the period that
   has already been paid for (the day before NextBillingDate).
   @Immediate = 1          : access ends today.
   ============================================================================= */
CREATE OR ALTER PROCEDURE acct.usp_CancelSubscription
    @SubscriptionID INT,
    @Reason         NVARCHAR(200) = NULL,
    @Immediate      BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @StartDate DATE, @NextBilling DATE, @Status VARCHAR(12), @EndDate DATE;

    SELECT @StartDate = s.StartDate, @NextBilling = s.NextBillingDate, @Status = s.SubscriptionStatus
    FROM acct.Subscription AS s
    WHERE s.SubscriptionID = @SubscriptionID;

    IF @StartDate IS NULL
        THROW 50020, 'Subscription not found.', 1;

    IF @Status IN ('Cancelled', 'Expired')
        THROW 50021, 'The subscription is already cancelled or expired.', 1;

    SET @EndDate = CASE WHEN @Immediate = 1 OR @NextBilling IS NULL OR @NextBilling <= @Today
                        THEN @Today
                        ELSE DATEADD(DAY, -1, @NextBilling) END;
    IF @EndDate < @StartDate SET @EndDate = @StartDate;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE acct.Subscription
           SET SubscriptionStatus = 'Cancelled',
               AutoRenew          = 0,
               CancelledAt        = SYSUTCDATETIME(),
               CancellationReason = @Reason,
               EndDate            = @EndDate,
               NextBillingDate    = NULL
         WHERE SubscriptionID = @SubscriptionID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   play.usp_RecordWatchSession
   Records one playback session. Rules checked here:
     - the profile's subscriber has a live subscription (entitlement),
     - the title is licensed in the country where it is watched,
     - the video quality is capped at the plan's MaxVideoQuality,
     - PercentComplete / IsCompleted are derived from the runtime.
   That the episode belongs to the title and that the device belongs to the
   subscriber is enforced by play.trg_WatchSession_ValidateEpisode.
   ============================================================================= */
CREATE OR ALTER PROCEDURE play.usp_RecordWatchSession
    @ProfileID        INT,
    @TitleID          INT,
    @EpisodeID        INT          = NULL,
    @DeviceID         INT,
    @CountryID        INT,
    @StartedAt        DATETIME2(0),
    @SecondsWatched   INT,
    @VideoQuality     VARCHAR(4)   = 'HD',
    @BufferingEvents  SMALLINT     = 0,
    @WatchSessionID   BIGINT       = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SubscriberID INT, @PlanID INT, @MaxQuality VARCHAR(4),
            @RuntimeMin INT, @Pct DECIMAL(5,2);

    SELECT @SubscriberID = p.SubscriberID FROM acct.Profile AS p WHERE p.ProfileID = @ProfileID;
    IF @SubscriberID IS NULL
        THROW 50030, 'Profile not found.', 1;

    SET @PlanID = acct.ufn_GetCurrentPlanID(@SubscriberID);
    IF @PlanID IS NULL
        THROW 50031, 'The subscriber has no live subscription.', 1;

    IF cat.ufn_IsTitleAvailable(@TitleID, @CountryID, CAST(@StartedAt AS DATE)) = 0
        THROW 50032, 'The title is not available in this country.', 1;

    SELECT @MaxQuality = pl.MaxVideoQuality FROM acct.[Plan] AS pl WHERE pl.PlanID = @PlanID;

    /* quality ladder SD < HD < FHD < 4K - never stream above the plan */
    IF CHARINDEX(@VideoQuality, 'SD HD FHD 4K') > CHARINDEX(@MaxQuality, 'SD HD FHD 4K')
        SET @VideoQuality = @MaxQuality;

    SELECT @RuntimeMin = CASE WHEN @EpisodeID IS NOT NULL
                              THEN (SELECT e.RuntimeMinutes FROM cat.Episode AS e WHERE e.EpisodeID = @EpisodeID)
                              ELSE (SELECT t.RuntimeMinutes FROM cat.Title   AS t WHERE t.TitleID   = @TitleID) END;

    SET @Pct = CASE WHEN ISNULL(@RuntimeMin, 0) = 0 THEN 0
                    WHEN @SecondsWatched >= @RuntimeMin * 60 THEN 100
                    ELSE CAST(100.0 * @SecondsWatched / (@RuntimeMin * 60) AS DECIMAL(5,2)) END;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO play.WatchSession
            (ProfileID, TitleID, EpisodeID, DeviceID, CountryID, StartedAt, EndedAt,
             SecondsWatched, PercentComplete, VideoQuality, IsCompleted, BufferingEvents)
        VALUES
            (@ProfileID, @TitleID, @EpisodeID, @DeviceID, @CountryID, @StartedAt,
             DATEADD(SECOND, @SecondsWatched, @StartedAt),
             @SecondsWatched, @Pct, @VideoQuality,
             CASE WHEN @Pct >= 90 THEN 1 ELSE 0 END, @BufferingEvents);

        SET @WatchSessionID = SCOPE_IDENTITY();

        UPDATE acct.Device SET LastSeenAt = @StartedAt
         WHERE DeviceID = @DeviceID AND (LastSeenAt IS NULL OR LastSeenAt < @StartedAt);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   play.usp_AddOrUpdateReview
   One review per profile and title (UQ_Review_PerUser). A second call for the
   same pair edits the review and stamps UpdatedAt - the incremental ETL picks
   edits up through that column. A profile may only review a title it has
   watched. The title's average rating is maintained by
   play.trg_Review_SyncTitleRating.
   ============================================================================= */
CREATE OR ALTER PROCEDURE play.usp_AddOrUpdateReview
    @ProfileID    INT,
    @TitleID      INT,
    @RatingValue  TINYINT,
    @ReviewTitle  NVARCHAR(150)  = NULL,
    @ReviewText   NVARCHAR(2000) = NULL,
    @ReviewID     INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RatingValue NOT BETWEEN 1 AND 10
        THROW 50040, 'The rating must be between 1 and 10.', 1;

    IF NOT EXISTS (SELECT 1 FROM play.WatchSession WHERE ProfileID = @ProfileID AND TitleID = @TitleID)
        THROW 50041, 'A profile can only review a title it has watched.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @ReviewID = r.ReviewID
        FROM play.Review AS r WITH (UPDLOCK, HOLDLOCK)
        WHERE r.ProfileID = @ProfileID AND r.TitleID = @TitleID;

        IF @ReviewID IS NULL
        BEGIN
            INSERT INTO play.Review (ProfileID, TitleID, RatingValue, ReviewTitle, ReviewText)
            VALUES (@ProfileID, @TitleID, @RatingValue, @ReviewTitle, @ReviewText);

            SET @ReviewID = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE play.Review
               SET RatingValue = @RatingValue,
                   ReviewTitle = @ReviewTitle,
                   ReviewText  = @ReviewText,
                   UpdatedAt   = SYSUTCDATETIME()
             WHERE ReviewID = @ReviewID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   bill.usp_GenerateInvoice
   Issues the next invoice of a subscription:
     Period   NextBillingDate (or StartDate) for one month / one year.
     Subtotal plan MonthlyPrice, or AnnualPrice for an Annual cycle.
     Discount the best coupon applied to the subscription and valid on the
              issue date (percentage or fixed amount, never above the subtotal).
     Tax      @TaxRatePct of (subtotal - discount).
   Afterwards NextBillingDate moves to the day after the period end.
   ============================================================================= */
CREATE OR ALTER PROCEDURE bill.usp_GenerateInvoice
    @SubscriptionID INT,
    @IssuedDate     DATE          = NULL,
    @TaxRatePct     DECIMAL(5,2)  = 20.00,
    @InvoiceID      INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PeriodStart DATE, @PeriodEnd DATE, @Cycle VARCHAR(8), @Status VARCHAR(12),
            @Subtotal DECIMAL(10,2), @Discount DECIMAL(10,2), @Tax DECIMAL(10,2),
            @Currency CHAR(3), @InvoiceNumber VARCHAR(20);

    SET @IssuedDate = ISNULL(@IssuedDate, CAST(SYSUTCDATETIME() AS DATE));

    SELECT @PeriodStart = ISNULL(s.NextBillingDate, s.StartDate),
           @Cycle       = s.BillingCycle,
           @Status      = s.SubscriptionStatus,
           @Currency    = p.CurrencyCode,
           @Subtotal    = CASE WHEN s.BillingCycle = 'Annual' AND p.AnnualPrice IS NOT NULL
                               THEN p.AnnualPrice ELSE p.MonthlyPrice END
    FROM acct.Subscription AS s
    INNER JOIN acct.[Plan] AS p ON p.PlanID = s.PlanID
    WHERE s.SubscriptionID = @SubscriptionID;

    IF @PeriodStart IS NULL
        THROW 50050, 'Subscription not found.', 1;

    IF @Status IN ('Cancelled', 'Expired')
        THROW 50051, 'A cancelled or expired subscription is not invoiced.', 1;

    SET @PeriodEnd = DATEADD(DAY, -1, CASE WHEN @Cycle = 'Annual'
                                           THEN DATEADD(YEAR, 1, @PeriodStart)
                                           ELSE DATEADD(MONTH, 1, @PeriodStart) END);

    IF EXISTS (SELECT 1 FROM bill.Invoice
                WHERE SubscriptionID = @SubscriptionID AND PeriodStart = @PeriodStart
                  AND InvoiceStatus <> 'Void')
        THROW 50052, 'This billing period has already been invoiced.', 1;

    SELECT @Discount = ISNULL(MAX(CASE WHEN c.DiscountPercent IS NOT NULL
                                       THEN ROUND(@Subtotal * c.DiscountPercent / 100.0, 2)
                                       ELSE c.DiscountAmount END), 0)
    FROM bill.SubscriptionCoupon AS sc
    INNER JOIN bill.Coupon AS c ON c.CouponID = sc.CouponID
    WHERE sc.SubscriptionID = @SubscriptionID
      AND @IssuedDate BETWEEN c.ValidFrom AND c.ValidTo;

    IF @Discount > @Subtotal SET @Discount = @Subtotal;
    SET @Tax = ROUND((@Subtotal - @Discount) * @TaxRatePct / 100.0, 2);
    SET @InvoiceNumber = 'INV-' + CAST(@SubscriptionID AS VARCHAR(7)) + '-'
                       + CONVERT(CHAR(8), @PeriodStart, 112);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO bill.Invoice
            (SubscriptionID, InvoiceNumber, IssuedDate, DueDate, PeriodStart, PeriodEnd,
             SubtotalAmount, DiscountAmount, TaxAmount, TotalAmount, CurrencyCode, InvoiceStatus)
        VALUES
            (@SubscriptionID, @InvoiceNumber, @IssuedDate, DATEADD(DAY, 7, @IssuedDate),
             @PeriodStart, @PeriodEnd, @Subtotal, @Discount, @Tax,
             @Subtotal - @Discount + @Tax, @Currency, 'Open');

        SET @InvoiceID = SCOPE_IDENTITY();

        UPDATE acct.Subscription
           SET NextBillingDate = DATEADD(DAY, 1, @PeriodEnd)
         WHERE SubscriptionID = @SubscriptionID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   bill.usp_RecordPayment
   Records one payment attempt against an invoice. @Amount defaults to the
   open balance (bill.ufn_GetInvoiceBalance). The invoice status is settled by
   bill.trg_Payment_SettleInvoice; this procedure keeps the SUBSCRIPTION in
   step: a failed payment moves an Active subscription to PastDue, a successful
   one brings a PastDue subscription back to Active.
   ============================================================================= */
CREATE OR ALTER PROCEDURE bill.usp_RecordPayment
    @InvoiceID         INT,
    @PaymentMethodID   INT,
    @Amount            DECIMAL(10,2) = NULL,
    @PaymentStatus     VARCHAR(10)   = 'Succeeded',
    @GatewayReference  VARCHAR(50)   = NULL,
    @FailureReason     NVARCHAR(200) = NULL,
    @PaymentID         INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SubscriptionID INT, @SubscriberID INT, @InvoiceStatus VARCHAR(14), @Currency CHAR(3);

    SELECT @SubscriptionID = i.SubscriptionID, @SubscriberID = s.SubscriberID,
           @InvoiceStatus  = i.InvoiceStatus,  @Currency     = i.CurrencyCode
    FROM bill.Invoice AS i
    INNER JOIN acct.Subscription AS s ON s.SubscriptionID = i.SubscriptionID
    WHERE i.InvoiceID = @InvoiceID;

    IF @SubscriptionID IS NULL
        THROW 50060, 'Invoice not found.', 1;

    IF @InvoiceStatus IN ('Paid', 'Void', 'Refunded')
        THROW 50061, 'The invoice is already settled or void.', 1;

    IF NOT EXISTS (SELECT 1 FROM bill.PaymentMethod
                    WHERE PaymentMethodID = @PaymentMethodID
                      AND SubscriberID    = @SubscriberID
                      AND IsActive        = 1)
        THROW 50062, 'The payment method does not belong to the subscriber or is inactive.', 1;

    SET @Amount = ISNULL(@Amount, bill.ufn_GetInvoiceBalance(@InvoiceID));

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO bill.Payment
            (InvoiceID, PaymentMethodID, Amount, CurrencyCode, PaymentStatus,
             GatewayReference, FailureReason)
        VALUES
            (@InvoiceID, @PaymentMethodID, @Amount, @Currency, @PaymentStatus,
             @GatewayReference, CASE WHEN @PaymentStatus = 'Failed' THEN @FailureReason END);

        SET @PaymentID = SCOPE_IDENTITY();

        UPDATE acct.Subscription
           SET SubscriptionStatus = CASE WHEN @PaymentStatus = 'Failed'    THEN 'PastDue'
                                         WHEN @PaymentStatus = 'Succeeded' THEN 'Active' END
         WHERE SubscriptionID = @SubscriptionID
           AND (   (@PaymentStatus = 'Failed'    AND SubscriptionStatus = 'Active')
                OR (@PaymentStatus = 'Succeeded' AND SubscriptionStatus = 'PastDue'));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT 'HBOMaxOLTP: 7 stored procedures created.';
GO
