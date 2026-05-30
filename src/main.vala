using Singularity.Apps.Git;

int main (string[] args) {
    var app = new GitApp ();
    return app.run (args);
}
