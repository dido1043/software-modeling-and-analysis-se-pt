/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    06_triggers.sql
   Purpose: 7 AFTER triggers for rules that span rows or tables, derived
            counters and the subscription audit trail.
   Target:  Microsoft SQL Server 2019+
   Depends: 02_tables.sql and 04_functions.sql must have run first.

   Trigger                                 Table                 Fires on
   --------------------------------------  --------------------  -------------
   acct.trg_Subscription_Audit             acct.Subscription     INSERT, UPDATE
   acct.trg_Profile_EnforcePlanLimit       acct.Profile          INSERT, UPDATE
   play.trg_WatchSession_ValidateEpisode   play.WatchSession     INSERT, UPDATE
   cat.trg_Episode_SyncSeasonCount         cat.Episode           INSERT, UPDATE, DELETE
   play.trg_Review_SyncTitleRating         play.Review           INSERT, UPDATE, DELETE
   bill.trg_Payment_SettleInvoice          bill.Payment          INSERT, UPDATE
   bill.trg_SubscriptionCoupon_Redeem      bill.SubscriptionCoupon INSERT, DELETE

   Every trigger is SET-BASED: it works on the whole inserted / deleted
   pseudo-tables, so a multi-row INSERT or UPDATE (such as the seed script)
   is handled correctly. Validation triggers raise THROW 501xx, which rolls
   back the statement together with its transaction.
   ============================================================================= */

USE HBOMaxOLTP;
GO

/* =============================================================================
   acct.trg_Subscription_Audit
   Writes the history that acct.Subscription itself does not keep:
     INSERT                          -> 'Created'
     PlanID changed                  -> 'PlanChange'
     SubscriptionStatus changed      -> 'StatusChange'
     both changed                    -> 'PlanAndStatusChange'
     only AutoRenew changed          -> 'AutoRenewToggle'
   The warehouse function etl.utvf_PlanInForce reads the plan-change rows to
   find the plan a subscription was on at any past moment.
   A subscription created with a back-dated StartDate is logged at that date,
   so the history stays in chronological order.
   ============================================================================= */
CREATE OR ALTER TRIGGER acct.trg_Subscription_Audit
ON acct.Subscription
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF NOT EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO audit.SubscriptionChangeLog
            (SubscriptionID, ChangeType, OldPlanID, NewPlanID, OldStatus, NewStatus, ChangedAt)
        SELECT i.SubscriptionID, 'Created', NULL, i.PlanID, NULL, i.SubscriptionStatus,
               CASE WHEN i.StartDate < CAST(SYSUTCDATETIME() AS DATE)
                    THEN CAST(i.StartDate AS DATETIME2(0))
                    ELSE SYSUTCDATETIME() END
        FROM inserted AS i;
        RETURN;
    END

    INSERT INTO audit.SubscriptionChangeLog
        (SubscriptionID, ChangeType, OldPlanID, NewPlanID, OldStatus, NewStatus)
    SELECT
        i.SubscriptionID,
        CASE WHEN i.PlanID <> d.PlanID AND i.SubscriptionStatus <> d.SubscriptionStatus
                  THEN 'PlanAndStatusChange'
             WHEN i.PlanID <> d.PlanID             THEN 'PlanChange'
             WHEN i.SubscriptionStatus <> d.SubscriptionStatus THEN 'StatusChange'
             ELSE 'AutoRenewToggle' END,
        d.PlanID, i.PlanID,
        d.SubscriptionStatus, i.SubscriptionStatus
    FROM inserted AS i
    INNER JOIN deleted AS d ON d.SubscriptionID = i.SubscriptionID
    WHERE i.PlanID <> d.PlanID
       OR i.SubscriptionStatus <> d.SubscriptionStatus
       OR i.AutoRenew <> d.AutoRenew;
END
GO

/* =============================================================================
   acct.trg_Profile_EnforcePlanLimit
   A subscriber may not have more profiles than the MaxProfiles of the plan of
   their most recent subscription (1 when they have no subscription at all).
   ============================================================================= */
CREATE OR ALTER TRIGGER acct.trg_Profile_EnforcePlanLimit
ON acct.Profile
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF EXISTS
    (
        SELECT 1
        FROM (SELECT DISTINCT SubscriberID FROM inserted) AS a
        CROSS APPLY (SELECT COUNT(*) AS ProfileCount
                     FROM acct.Profile AS p
                     WHERE p.SubscriberID = a.SubscriberID) AS c
        OUTER APPLY (SELECT TOP (1) pl.MaxProfiles
                     FROM acct.Subscription AS s
                     INNER JOIN acct.[Plan] AS pl ON pl.PlanID = s.PlanID
                     WHERE s.SubscriberID = a.SubscriberID
                     ORDER BY s.StartDate DESC, s.SubscriptionID DESC) AS lim
        WHERE c.ProfileCount > ISNULL(lim.MaxProfiles, 1)
    )
        THROW 50101, 'The number of profiles exceeds the limit of the subscriber''s plan.', 1;
END
GO

/* =============================================================================
   play.trg_WatchSession_ValidateEpisode
   Two cross-table rules that a CHECK constraint cannot express:
     1. the EpisodeID (when given) belongs to a season of the watched TitleID;
     2. the device belongs to the same subscriber as the profile.
   ============================================================================= */
CREATE OR ALTER TRIGGER play.trg_WatchSession_ValidateEpisode
ON play.WatchSession
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        INNER JOIN cat.Episode AS e ON e.EpisodeID = i.EpisodeID
        INNER JOIN cat.Season  AS s ON s.SeasonID  = e.SeasonID
        WHERE s.TitleID <> i.TitleID
    )
        THROW 50102, 'The episode does not belong to the watched title.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        INNER JOIN acct.Profile AS p ON p.ProfileID = i.ProfileID
        INNER JOIN acct.Device  AS d ON d.DeviceID  = i.DeviceID
        WHERE d.SubscriberID <> p.SubscriberID
    )
        THROW 50103, 'The device is not registered to the profile''s subscriber.', 1;
END
GO

/* =============================================================================
   cat.trg_Episode_SyncSeasonCount
   Keeps cat.Season.EpisodeCount equal to the number of its episodes. Seasons
   on both sides of the change are recounted, so moving an episode to another
   season updates both.
   ============================================================================= */
CREATE OR ALTER TRIGGER cat.trg_Episode_SyncSeasonCount
ON cat.Episode
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE s
       SET EpisodeCount = CAST((SELECT COUNT(*) FROM cat.Episode AS e
                                WHERE e.SeasonID = s.SeasonID) AS SMALLINT)
      FROM cat.Season AS s
     WHERE s.SeasonID IN (SELECT SeasonID FROM inserted
                          UNION
                          SELECT SeasonID FROM deleted);
END
GO

/* =============================================================================
   play.trg_Review_SyncTitleRating
   Keeps cat.Title.AverageUserRating and UserRatingCount in step with
   play.Review for every title touched by the statement.
   ============================================================================= */
CREATE OR ALTER TRIGGER play.trg_Review_SyncTitleRating
ON play.Review
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE t
       SET AverageUserRating = agg.AvgRating,
           UserRatingCount   = ISNULL(agg.RatingCount, 0)
      FROM cat.Title AS t
      OUTER APPLY
      (
          SELECT CAST(AVG(CAST(r.RatingValue AS DECIMAL(6,2))) AS DECIMAL(4,2)) AS AvgRating,
                 COUNT(*)                                                     AS RatingCount
          FROM play.Review AS r
          WHERE r.TitleID = t.TitleID
      ) AS agg
     WHERE t.TitleID IN (SELECT TitleID FROM inserted
                         UNION
                         SELECT TitleID FROM deleted);
END
GO

/* =============================================================================
   bill.trg_Payment_SettleInvoice
   Recomputes the status of every invoice touched by a payment change:
     succeeded amount >= total      -> 'Paid'
     some succeeded amount          -> 'PartiallyPaid'
     only refunded payments         -> 'Refunded'
     nothing paid, past due date    -> 'Overdue'
     nothing paid                   -> 'Open'
   A 'Void' invoice is never changed.
   ============================================================================= */
CREATE OR ALTER TRIGGER bill.trg_Payment_SettleInvoice
ON bill.Payment
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    UPDATE inv
       SET InvoiceStatus = CASE WHEN x.Paid >= inv.TotalAmount AND x.Paid > 0 THEN 'Paid'
                                WHEN x.Paid > 0                               THEN 'PartiallyPaid'
                                WHEN x.Refunded > 0                           THEN 'Refunded'
                                WHEN inv.DueDate < CAST(SYSUTCDATETIME() AS DATE) THEN 'Overdue'
                                ELSE 'Open' END
      FROM bill.Invoice AS inv
      CROSS APPLY
      (
          SELECT ISNULL(SUM(CASE WHEN p.PaymentStatus = 'Succeeded' THEN p.Amount END), 0) AS Paid,
                 ISNULL(SUM(CASE WHEN p.PaymentStatus = 'Refunded'  THEN p.Amount END), 0) AS Refunded
          FROM bill.Payment AS p
          WHERE p.InvoiceID = inv.InvoiceID
      ) AS x
     WHERE inv.InvoiceID IN (SELECT InvoiceID FROM inserted
                             UNION
                             SELECT InvoiceID FROM deleted)
       AND inv.InvoiceStatus <> 'Void';
END
GO

/* =============================================================================
   bill.trg_SubscriptionCoupon_Redeem
   On INSERT: the coupon must be valid on the AppliedAt date, TimesRedeemed is
              increased, and MaxRedemptions may not be exceeded.
   On DELETE: TimesRedeemed is decreased again.
   ============================================================================= */
CREATE OR ALTER TRIGGER bill.trg_SubscriptionCoupon_Redeem
ON bill.SubscriptionCoupon
AFTER INSERT, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        INNER JOIN bill.Coupon AS c ON c.CouponID = i.CouponID
        WHERE CAST(i.AppliedAt AS DATE) NOT BETWEEN c.ValidFrom AND c.ValidTo
    )
        THROW 50104, 'The coupon is not valid on the date it was applied.', 1;

    UPDATE c
       SET TimesRedeemed = c.TimesRedeemed + ISNULL(ins.Cnt, 0) - ISNULL(del.Cnt, 0)
      FROM bill.Coupon AS c
      LEFT JOIN (SELECT CouponID, COUNT(*) AS Cnt FROM inserted GROUP BY CouponID) AS ins
             ON ins.CouponID = c.CouponID
      LEFT JOIN (SELECT CouponID, COUNT(*) AS Cnt FROM deleted  GROUP BY CouponID) AS del
             ON del.CouponID = c.CouponID
     WHERE ins.CouponID IS NOT NULL OR del.CouponID IS NOT NULL;

    IF EXISTS
    (
        SELECT 1
        FROM bill.Coupon AS c
        WHERE c.CouponID IN (SELECT CouponID FROM inserted)
          AND c.MaxRedemptions IS NOT NULL
          AND c.TimesRedeemed > c.MaxRedemptions
    )
        THROW 50105, 'The coupon has reached its maximum number of redemptions.', 1;
END
GO

PRINT 'HBOMaxOLTP: 7 triggers created.';
GO
