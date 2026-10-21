/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    04_functions.sql
   Purpose: 7 user-defined functions - 5 scalar, 2 inline table-valued.
   Target:  Microsoft SQL Server 2019+
   Depends: 02_tables.sql must have run first.

   Function                              Kind     Used by
   ------------------------------------  -------  -----------------------------
   acct.ufn_GetAge                       scalar   07_views, reports
   acct.ufn_GetCurrentPlanID             scalar   06_triggers (profile limit),
                                                  05_stored_procedures
   cat.ufn_IsTitleAvailable              scalar   play.usp_RecordWatchSession
   cat.ufn_GetTitleTotalRuntime          scalar   07_views
   bill.ufn_GetInvoiceBalance            scalar   06_triggers (settlement),
                                                  07_views
   play.itvf_ContinueWatching            inline   "Continue watching" row
   cat.itvf_TopTitlesByHoursWatched      inline   ad-hoc top-N reporting

   Inline TVFs are preferred over multi-statement TVFs because the optimiser
   expands them into the calling query. The scalar functions are short,
   deterministic where possible, and safe to inline (SQL Server 2019+).
   ============================================================================= */

USE HBOMaxOLTP;
GO

/* =============================================================================
   acct.ufn_GetAge
   Age in whole years on @AsOf. DATEDIFF(YEAR, ...) alone counts year
   boundaries, so one is subtracted when the birthday has not happened yet in
   the @AsOf year.
   ============================================================================= */
CREATE OR ALTER FUNCTION acct.ufn_GetAge
(
    @DateOfBirth DATE,
    @AsOf        DATE
)
RETURNS INT
AS
BEGIN
    IF @DateOfBirth IS NULL OR @AsOf IS NULL OR @AsOf < @DateOfBirth
        RETURN NULL;

    RETURN DATEDIFF(YEAR, @DateOfBirth, @AsOf)
         - CASE WHEN MONTH(@DateOfBirth) > MONTH(@AsOf)
                  OR (MONTH(@DateOfBirth) = MONTH(@AsOf) AND DAY(@DateOfBirth) > DAY(@AsOf))
                THEN 1 ELSE 0 END;
END
GO

/* =============================================================================
   acct.ufn_GetCurrentPlanID
   The plan of the subscriber's live subscription: the latest-starting
   subscription that has not ended. A Cancelled subscription stays live until
   its EndDate (the end of the period already paid for); an Expired one never
   is. Returns NULL when the subscriber has no live subscription.
   ============================================================================= */
CREATE OR ALTER FUNCTION acct.ufn_GetCurrentPlanID
(
    @SubscriberID INT
)
RETURNS INT
AS
BEGIN
    DECLARE @PlanID INT;

    SELECT TOP (1) @PlanID = s.PlanID
    FROM acct.Subscription AS s
    WHERE s.SubscriberID = @SubscriberID
      AND s.SubscriptionStatus <> 'Expired'
      AND (s.EndDate IS NULL OR s.EndDate >= CAST(SYSUTCDATETIME() AS DATE))
      AND (s.SubscriptionStatus <> 'Cancelled' OR s.EndDate IS NOT NULL)
    ORDER BY s.StartDate DESC, s.SubscriptionID DESC;

    RETURN @PlanID;
END
GO

/* =============================================================================
   cat.ufn_IsTitleAvailable
   1 when the title is in the catalogue and licensed in the country on @AsOf.
   ============================================================================= */
CREATE OR ALTER FUNCTION cat.ufn_IsTitleAvailable
(
    @TitleID   INT,
    @CountryID INT,
    @AsOf      DATE
)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS
    (
        SELECT 1
        FROM cat.TitleAvailability AS ta
        INNER JOIN cat.Title AS t ON t.TitleID = ta.TitleID
        WHERE ta.TitleID   = @TitleID
          AND ta.CountryID = @CountryID
          AND ta.LicenseType <> 'Expired'
          AND ta.AvailableFrom <= @AsOf
          AND (ta.AvailableUntil IS NULL OR ta.AvailableUntil >= @AsOf)
          AND (t.RemovedFromCatalogAt IS NULL OR CAST(t.RemovedFromCatalogAt AS DATE) > @AsOf)
    ) THEN 1 ELSE 0 END;
END
GO

/* =============================================================================
   cat.ufn_GetTitleTotalRuntime
   Total minutes of content: the title runtime for a single programme, the sum
   of all episode runtimes for a series. 0 when nothing is known.
   ============================================================================= */
CREATE OR ALTER FUNCTION cat.ufn_GetTitleTotalRuntime
(
    @TitleID INT
)
RETURNS INT
AS
BEGIN
    DECLARE @Minutes INT;

    SELECT @Minutes = SUM(CAST(e.RuntimeMinutes AS INT))
    FROM cat.Season AS s
    INNER JOIN cat.Episode AS e ON e.SeasonID = s.SeasonID
    WHERE s.TitleID = @TitleID;

    IF @Minutes IS NULL
        SELECT @Minutes = CAST(t.RuntimeMinutes AS INT)
        FROM cat.Title AS t
        WHERE t.TitleID = @TitleID;

    RETURN ISNULL(@Minutes, 0);
END
GO

/* =============================================================================
   bill.ufn_GetInvoiceBalance
   Amount still owed on an invoice: TotalAmount minus succeeded payments.
   A refunded payment no longer counts as paid. Never negative.
   ============================================================================= */
CREATE OR ALTER FUNCTION bill.ufn_GetInvoiceBalance
(
    @InvoiceID INT
)
RETURNS DECIMAL(10,2)
AS
BEGIN
    DECLARE @Total DECIMAL(10,2), @Paid DECIMAL(10,2);

    SELECT @Total = i.TotalAmount
    FROM bill.Invoice AS i
    WHERE i.InvoiceID = @InvoiceID;

    SELECT @Paid = ISNULL(SUM(p.Amount), 0)
    FROM bill.Payment AS p
    WHERE p.InvoiceID = @InvoiceID
      AND p.PaymentStatus = 'Succeeded';

    RETURN CASE WHEN @Total IS NULL       THEN NULL
                WHEN @Total - @Paid < 0   THEN 0
                ELSE @Total - @Paid END;
END
GO

/* =============================================================================
   play.itvf_ContinueWatching
   The "Continue watching" row of a profile: the latest unfinished session per
   title, most recent first.
   ============================================================================= */
CREATE OR ALTER FUNCTION play.itvf_ContinueWatching
(
    @ProfileID INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        x.TitleID,
        x.PrimaryTitle,
        x.EpisodeID,
        x.EpisodeTitle,
        x.PercentComplete,
        x.LastWatchedAt
    FROM
    (
        SELECT
            ws.TitleID,
            t.PrimaryTitle,
            ws.EpisodeID,
            e.EpisodeTitle,
            ws.PercentComplete,
            ws.StartedAt AS LastWatchedAt,
            ROW_NUMBER() OVER (PARTITION BY ws.TitleID
                               ORDER BY ws.StartedAt DESC, ws.WatchSessionID DESC) AS rn
        FROM play.WatchSession AS ws
        INNER JOIN cat.Title  AS t ON t.TitleID = ws.TitleID
        LEFT  JOIN cat.Episode AS e ON e.EpisodeID = ws.EpisodeID
        WHERE ws.ProfileID = @ProfileID
    ) AS x
    WHERE x.rn = 1
      AND x.PercentComplete < 95
);
GO

/* =============================================================================
   cat.itvf_TopTitlesByHoursWatched
   Top @TopN titles by hours watched in [@From, @To).
   ============================================================================= */
CREATE OR ALTER FUNCTION cat.itvf_TopTitlesByHoursWatched
(
    @From DATE,
    @To   DATE,
    @TopN INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (@TopN)
        t.TitleID,
        t.PrimaryTitle,
        t.TitleType,
        CAST(SUM(CAST(ws.SecondsWatched AS BIGINT)) / 3600.0 AS DECIMAL(12,2)) AS HoursWatched,
        COUNT(DISTINCT ws.ProfileID)                                            AS UniqueViewers,
        COUNT(*)                                                                AS SessionCount
    FROM play.WatchSession AS ws
    INNER JOIN cat.Title AS t ON t.TitleID = ws.TitleID
    WHERE ws.StartedAt >= @From
      AND ws.StartedAt <  @To
    GROUP BY t.TitleID, t.PrimaryTitle, t.TitleType
    ORDER BY HoursWatched DESC, t.TitleID
);
GO

PRINT 'HBOMaxOLTP: 7 functions created.';
GO
