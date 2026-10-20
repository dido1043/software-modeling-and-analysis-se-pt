/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    16_run_full_load.sql
   Purpose: Run the complete ETL (etl.usp_RunFullLoad) and print a load report:
              1. the audit trail of this run, one row per procedure
              2. row counts of every warehouse table
              3. source-to-target reconciliation for the transaction facts
              4. DATA QUALITY - how many fact rows landed on each Unknown (-1)
                 member, per fact and per dimension
              5. a smoke test of the seven analytic views
   Target:  Microsoft SQL Server 2019+
   Depends: 01-08 (HBOMaxOLTP populated) and 10-15 (HBOMaxDW built), all on the
            same instance.
   Order:   the last script: run 10 -> 11 -> 12 -> 13 -> 14 -> 15 -> 16.
   Notes:   Safe to run any number of times. @FullReload = 1 makes the run
            independent of earlier watermarks, so this script always produces
            the same warehouse from the same source. For a routine incremental
            refresh run   EXEC etl.usp_RunFullLoad;   instead.
   ============================================================================= */

USE HBOMaxDW;
GO

SET NOCOUNT ON;

DECLARE @BatchID UNIQUEIDENTIFIER;

PRINT '16_run_full_load.sql - starting etl.usp_RunFullLoad (full reload) ...';

EXEC etl.usp_RunFullLoad @FullReload = 1, @BatchID = @BatchID OUTPUT;

PRINT 'Load finished. BatchID = ' + CONVERT(VARCHAR(36), @BatchID);

/* Keep the batch id for the report batches below. */
DROP TABLE IF EXISTS #LastBatch;
SELECT @BatchID AS BatchID INTO #LastBatch;
GO

/* =============================================================================
   1. AUDIT TRAIL OF THIS RUN
   ============================================================================= */
SELECT
    a.LoadAuditID,
    a.ProcedureName,
    a.TargetObject,
    a.LoadType,
    a.LoadStatus,
    a.RowsRead,
    a.RowsInserted,
    a.RowsUpdated,
    a.RowsRejected        AS RowsOnUnknownMember,
    a.DurationSeconds,
    a.ErrorMessage
FROM etl.LoadAudit AS a
INNER JOIN #LastBatch AS b ON b.BatchID = a.BatchID
ORDER BY a.LoadAuditID;
GO

/* =============================================================================
   2. ROW COUNTS OF EVERY WAREHOUSE TABLE
   The -1 Unknown member is excluded from the dimension counts.
   ============================================================================= */
SELECT 'Dimension' AS TableKind, 'dw.DimDate'          AS TableName, COUNT(*) AS RowCnt FROM dw.DimDate          WHERE DateKey          <> -1
UNION ALL SELECT 'Dimension', 'dw.DimTimeOfDay',      COUNT(*) FROM dw.DimTimeOfDay     WHERE TimeKey          <> -1
UNION ALL SELECT 'Dimension', 'dw.DimSubscriber',     COUNT(*) FROM dw.DimSubscriber    WHERE SubscriberKey    <> -1
UNION ALL SELECT 'Dimension', 'dw.DimProfile',        COUNT(*) FROM dw.DimProfile       WHERE ProfileKey       <> -1
UNION ALL SELECT 'Dimension', 'dw.DimTitle',          COUNT(*) FROM dw.DimTitle         WHERE TitleKey         <> -1
UNION ALL SELECT 'Dimension', 'dw.DimGenre',          COUNT(*) FROM dw.DimGenre         WHERE GenreKey         <> -1
UNION ALL SELECT 'Dimension', 'dw.DimDevice',         COUNT(*) FROM dw.DimDevice        WHERE DeviceKey        <> -1
UNION ALL SELECT 'Dimension', 'dw.DimGeography',      COUNT(*) FROM dw.DimGeography     WHERE GeographyKey     <> -1
UNION ALL SELECT 'Dimension', 'dw.DimPlan',           COUNT(*) FROM dw.DimPlan          WHERE PlanKey          <> -1
UNION ALL SELECT 'Dimension', 'dw.DimPaymentMethod',  COUNT(*) FROM dw.DimPaymentMethod WHERE PaymentMethodKey <> -1
UNION ALL SELECT 'Fact', 'dw.FactViewingSession',               COUNT(*) FROM dw.FactViewingSession
UNION ALL SELECT 'Fact', 'dw.FactSubscriptionMonthlySnapshot',  COUNT(*) FROM dw.FactSubscriptionMonthlySnapshot
UNION ALL SELECT 'Fact', 'dw.FactRevenue',                      COUNT(*) FROM dw.FactRevenue
UNION ALL SELECT 'Fact', 'dw.FactTitleRating',                  COUNT(*) FROM dw.FactTitleRating
UNION ALL SELECT 'Fact', 'dw.FactCatalogAvailabilitySnapshot',  COUNT(*) FROM dw.FactCatalogAvailabilitySnapshot
ORDER BY TableKind, TableName;
GO

/* =============================================================================
   3. SOURCE-TO-TARGET RECONCILIATION
   Every transaction fact has a one-row-per-source-row grain, so its row count
   must equal the source count, and the revenue amounts must tie back to the
   source payments. Any row with Status = 'MISMATCH' needs investigating.
   ============================================================================= */
WITH Checks AS
(
    SELECT 'WatchSession rows -> FactViewingSession' AS CheckName,
           CAST((SELECT COUNT(*) FROM HBOMaxOLTP.play.WatchSession) AS DECIMAL(18,2)) AS SourceValue,
           CAST((SELECT COUNT(*) FROM dw.FactViewingSession)        AS DECIMAL(18,2)) AS TargetValue
    UNION ALL
    SELECT 'Seconds watched',
           CAST((SELECT SUM(CAST(SecondsWatched AS BIGINT)) FROM HBOMaxOLTP.play.WatchSession) AS DECIMAL(18,2)),
           CAST((SELECT SUM(CAST(SecondsWatched AS BIGINT)) FROM dw.FactViewingSession)        AS DECIMAL(18,2))
    UNION ALL
    SELECT 'Payment rows -> FactRevenue',
           CAST((SELECT COUNT(*) FROM HBOMaxOLTP.bill.Payment) AS DECIMAL(18,2)),
           CAST((SELECT COUNT(*) FROM dw.FactRevenue)          AS DECIMAL(18,2))
    UNION ALL
    SELECT 'Settled payment amount (Succeeded + Refunded)',
           CAST((SELECT SUM(Amount) FROM HBOMaxOLTP.bill.Payment
                  WHERE PaymentStatus IN ('Succeeded', 'Refunded')) AS DECIMAL(18,2)),
           CAST((SELECT SUM(PaidAmount) FROM dw.FactRevenue)        AS DECIMAL(18,2))
    UNION ALL
    SELECT 'Refunded amount',
           CAST((SELECT ISNULL(SUM(Amount), 0) FROM HBOMaxOLTP.bill.Payment
                  WHERE PaymentStatus = 'Refunded')                  AS DECIMAL(18,2)),
           CAST((SELECT SUM(RefundedAmount) FROM dw.FactRevenue)     AS DECIMAL(18,2))
    UNION ALL
    SELECT 'Review rows -> FactTitleRating',
           CAST((SELECT COUNT(*) FROM HBOMaxOLTP.play.Review) AS DECIMAL(18,2)),
           CAST((SELECT COUNT(*) FROM dw.FactTitleRating)     AS DECIMAL(18,2))
    UNION ALL
    SELECT 'Average rating',
           CAST((SELECT AVG(CAST(RatingValue AS DECIMAL(9,4))) FROM HBOMaxOLTP.play.Review) AS DECIMAL(18,2)),
           CAST((SELECT AVG(CAST(RatingValue AS DECIMAL(9,4))) FROM dw.FactTitleRating)     AS DECIMAL(18,2))
)
SELECT
    CheckName,
    SourceValue,
    TargetValue,
    CASE WHEN ISNULL(SourceValue, 0) = ISNULL(TargetValue, 0) THEN 'OK' ELSE 'MISMATCH' END AS Status
FROM Checks;

/* Allocation check: the invoice amounts spread over the payment lines must
   never exceed the invoice (rounding can leave at most a cent per line short). */
SELECT
    'Invoices whose allocated subtotal exceeds the invoice' AS CheckName,
    COUNT(*)                                                AS InvoiceCount,
    CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'MISMATCH' END    AS Status
FROM
(
    SELECT f.InvoiceID, SUM(f.SubtotalAmount) AS AllocatedSubtotal
    FROM dw.FactRevenue AS f
    GROUP BY f.InvoiceID
) AS a
INNER JOIN HBOMaxOLTP.bill.Invoice AS i ON i.InvoiceID = a.InvoiceID
WHERE a.AllocatedSubtotal > i.SubtotalAmount + 0.01;
GO

/* =============================================================================
   4. DATA QUALITY - FACT ROWS ATTACHED TO AN UNKNOWN (-1) MEMBER
   The analytic views exclude -1 members from their groupings (see the header
   of 15_dw_analytic_views.sql), so this is where those rows are accounted for.
   Expected non-zero values:
     * FactViewingSession.PlanKey  - a session on a date no subscription covered.
     * FactViewingSession.GenreKey / FactTitleRating.GenreKey - a title with no
       genre assigned.
   FactCatalogAvailabilitySnapshot.AvailableUntilDateKey is deliberately not
   listed: -1 there means "open-ended licence", not a failed lookup.
   ============================================================================= */
SELECT FactTable, DimensionKey, UnknownRows, TotalRows,
       CAST(100.0 * UnknownRows / NULLIF(TotalRows, 0) AS DECIMAL(5,2)) AS UnknownPct
FROM
(
    SELECT 'FactViewingSession' AS FactTable, v.DimensionKey, v.UnknownRows,
           (SELECT COUNT(*) FROM dw.FactViewingSession) AS TotalRows
    FROM
    (
        SELECT
            SUM(CASE WHEN DateKey       = -1 THEN 1 ELSE 0 END) AS DateKey,
            SUM(CASE WHEN TimeKey       = -1 THEN 1 ELSE 0 END) AS TimeKey,
            SUM(CASE WHEN ProfileKey    = -1 THEN 1 ELSE 0 END) AS ProfileKey,
            SUM(CASE WHEN SubscriberKey = -1 THEN 1 ELSE 0 END) AS SubscriberKey,
            SUM(CASE WHEN TitleKey      = -1 THEN 1 ELSE 0 END) AS TitleKey,
            SUM(CASE WHEN GenreKey      = -1 THEN 1 ELSE 0 END) AS GenreKey,
            SUM(CASE WHEN DeviceKey     = -1 THEN 1 ELSE 0 END) AS DeviceKey,
            SUM(CASE WHEN GeographyKey  = -1 THEN 1 ELSE 0 END) AS GeographyKey,
            SUM(CASE WHEN PlanKey       = -1 THEN 1 ELSE 0 END) AS PlanKey
        FROM dw.FactViewingSession
    ) AS s
    UNPIVOT (UnknownRows FOR DimensionKey IN
             (DateKey, TimeKey, ProfileKey, SubscriberKey, TitleKey, GenreKey,
              DeviceKey, GeographyKey, PlanKey)) AS v

    UNION ALL

    SELECT 'FactRevenue', v.DimensionKey, v.UnknownRows,
           (SELECT COUNT(*) FROM dw.FactRevenue)
    FROM
    (
        SELECT
            SUM(CASE WHEN InvoiceDateKey   = -1 THEN 1 ELSE 0 END) AS InvoiceDateKey,
            SUM(CASE WHEN PaymentDateKey   = -1 THEN 1 ELSE 0 END) AS PaymentDateKey,
            SUM(CASE WHEN TimeKey          = -1 THEN 1 ELSE 0 END) AS TimeKey,
            SUM(CASE WHEN SubscriberKey    = -1 THEN 1 ELSE 0 END) AS SubscriberKey,
            SUM(CASE WHEN PlanKey          = -1 THEN 1 ELSE 0 END) AS PlanKey,
            SUM(CASE WHEN GeographyKey     = -1 THEN 1 ELSE 0 END) AS GeographyKey,
            SUM(CASE WHEN PaymentMethodKey = -1 THEN 1 ELSE 0 END) AS PaymentMethodKey
        FROM dw.FactRevenue
    ) AS s
    UNPIVOT (UnknownRows FOR DimensionKey IN
             (InvoiceDateKey, PaymentDateKey, TimeKey, SubscriberKey, PlanKey,
              GeographyKey, PaymentMethodKey)) AS v

    UNION ALL

    SELECT 'FactTitleRating', v.DimensionKey, v.UnknownRows,
           (SELECT COUNT(*) FROM dw.FactTitleRating)
    FROM
    (
        SELECT
            SUM(CASE WHEN DateKey       = -1 THEN 1 ELSE 0 END) AS DateKey,
            SUM(CASE WHEN TimeKey       = -1 THEN 1 ELSE 0 END) AS TimeKey,
            SUM(CASE WHEN TitleKey      = -1 THEN 1 ELSE 0 END) AS TitleKey,
            SUM(CASE WHEN GenreKey      = -1 THEN 1 ELSE 0 END) AS GenreKey,
            SUM(CASE WHEN ProfileKey    = -1 THEN 1 ELSE 0 END) AS ProfileKey,
            SUM(CASE WHEN SubscriberKey = -1 THEN 1 ELSE 0 END) AS SubscriberKey,
            SUM(CASE WHEN GeographyKey  = -1 THEN 1 ELSE 0 END) AS GeographyKey
        FROM dw.FactTitleRating
    ) AS s
    UNPIVOT (UnknownRows FOR DimensionKey IN
             (DateKey, TimeKey, TitleKey, GenreKey, ProfileKey, SubscriberKey,
              GeographyKey)) AS v

    UNION ALL

    SELECT 'FactSubscriptionMonthlySnapshot', v.DimensionKey, v.UnknownRows,
           (SELECT COUNT(*) FROM dw.FactSubscriptionMonthlySnapshot)
    FROM
    (
        SELECT
            SUM(CASE WHEN SnapshotDateKey = -1 THEN 1 ELSE 0 END) AS SnapshotDateKey,
            SUM(CASE WHEN SubscriberKey   = -1 THEN 1 ELSE 0 END) AS SubscriberKey,
            SUM(CASE WHEN PlanKey         = -1 THEN 1 ELSE 0 END) AS PlanKey,
            SUM(CASE WHEN GeographyKey    = -1 THEN 1 ELSE 0 END) AS GeographyKey,
            SUM(CASE WHEN SignupDateKey   = -1 THEN 1 ELSE 0 END) AS SignupDateKey
        FROM dw.FactSubscriptionMonthlySnapshot
    ) AS s
    UNPIVOT (UnknownRows FOR DimensionKey IN
             (SnapshotDateKey, SubscriberKey, PlanKey, GeographyKey, SignupDateKey)) AS v

    UNION ALL

    SELECT 'FactCatalogAvailabilitySnapshot', v.DimensionKey, v.UnknownRows,
           (SELECT COUNT(*) FROM dw.FactCatalogAvailabilitySnapshot)
    FROM
    (
        SELECT
            SUM(CASE WHEN SnapshotDateKey      = -1 THEN 1 ELSE 0 END) AS SnapshotDateKey,
            SUM(CASE WHEN TitleKey             = -1 THEN 1 ELSE 0 END) AS TitleKey,
            SUM(CASE WHEN GenreKey             = -1 THEN 1 ELSE 0 END) AS GenreKey,
            SUM(CASE WHEN GeographyKey         = -1 THEN 1 ELSE 0 END) AS GeographyKey,
            SUM(CASE WHEN AvailableFromDateKey = -1 THEN 1 ELSE 0 END) AS AvailableFromDateKey
        FROM dw.FactCatalogAvailabilitySnapshot
    ) AS s
    UNPIVOT (UnknownRows FOR DimensionKey IN
             (SnapshotDateKey, TitleKey, GenreKey, GeographyKey, AvailableFromDateKey)) AS v
) AS q
ORDER BY FactTable, DimensionKey;
GO

/* =============================================================================
   5. SMOKE TEST OF THE ANALYTIC VIEWS
   Each view must return rows once the facts are loaded; an empty result here
   means the matching report page would be blank.
   ============================================================================= */
SELECT 'dw.vw_ViewingTrendByMonthRegion'      AS ViewName, COUNT(*) AS RowCnt FROM dw.vw_ViewingTrendByMonthRegion
UNION ALL SELECT 'dw.vw_TopTitlesByHoursWatched',       COUNT(*) FROM dw.vw_TopTitlesByHoursWatched
UNION ALL SELECT 'dw.vw_RevenueAndMrrByPlan',           COUNT(*) FROM dw.vw_RevenueAndMrrByPlan
UNION ALL SELECT 'dw.vw_ChurnByCohort',                 COUNT(*) FROM dw.vw_ChurnByCohort
UNION ALL SELECT 'dw.vw_GenreEngagementByDayPart',      COUNT(*) FROM dw.vw_GenreEngagementByDayPart
UNION ALL SELECT 'dw.vw_DeviceMixByRegion',             COUNT(*) FROM dw.vw_DeviceMixByRegion
UNION ALL SELECT 'dw.vw_OriginalsVsLicensedPerformance', COUNT(*) FROM dw.vw_OriginalsVsLicensedPerformance;
GO

DROP TABLE IF EXISTS #LastBatch;
GO

PRINT '16_run_full_load.sql complete - see the five result sets for the load report.';
GO
