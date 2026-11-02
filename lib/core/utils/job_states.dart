/// The job states after which nothing more will happen, shared by bill
/// extraction and voice jobs. `cancelled` belongs here: without it a
/// cancelled job was not finished, so the app polled it for ever. Written
/// as the set of finished states rather than the unfinished ones, so a
/// status the server adds later keeps the app polling instead of being
/// mistaken for done.
const kFinishedJobStates = {'done', 'failed', 'cancelled'};

bool isFinishedJobStatus(String status) => kFinishedJobStates.contains(status);
