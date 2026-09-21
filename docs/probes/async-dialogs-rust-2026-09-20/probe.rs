use std::future::{Future, pending};

fn local_task<'a>(_: impl Future<Output = ()> + 'a) {}

pub fn example(ctx: &kaya::AppCtx) {
    local_task(async move {
        let () = ctx.apply(|_| {});
        pending::<()>().await;
        ctx.apply(|_| {});
    });
}
